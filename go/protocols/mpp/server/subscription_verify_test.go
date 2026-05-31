package server

import (
	"context"
	"errors"
	"strings"
	"testing"

	solana "github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/rpc"

	"github.com/solana-foundation/pay-kit/go/internal/testutil"
	"github.com/solana-foundation/pay-kit/go/paycore"
	"github.com/solana-foundation/pay-kit/go/paycore/solanatx"
	"github.com/solana-foundation/pay-kit/go/paycore/subscriptions"
	core "github.com/solana-foundation/pay-kit/go/protocols/mpp/core"
	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
)

// activationFixture builds a well-formed activation transaction + credential
// for a server, returning the subscriber and the SubscriptionDelegation PDA so
// tests can seed the readback account.
type activationFixture struct {
	subscriber      solana.PrivateKey
	subscriptionPDA solana.PublicKey
	encodedTx       string
}

func buildActivationFixture(t *testing.T, cfg SubscriptionConfig, server *SubscriptionServer, blockhash solana.Hash, feePayer solana.PublicKey, useFeePayer bool) activationFixture {
	t.Helper()
	program := subscriptions.DefaultProgramID()
	subscriber := testutil.NewPrivateKey()
	puller := solana.MustPublicKeyFromBase58(cfg.Puller)
	planPDA := solana.MustPublicKeyFromBase58(cfg.PlanID)
	mint := solana.MustPublicKeyFromBase58(cfg.Mint)
	eventAuthority, _, _ := subscriptions.FindEventAuthorityPDA(program)
	subscriptionPDA, _, _ := subscriptions.FindSubscriptionPDA(planPDA, subscriber.PublicKey(), program)
	subscriptionAuthority, _, _ := subscriptions.FindSubscriptionAuthorityPDA(subscriber.PublicKey(), mint, program)
	subscriberATA, _ := solanatx.FindAssociatedTokenAddressWithProgram(subscriber.PublicKey(), mint, solana.TokenProgramID)
	recipientKey := solana.MustPublicKeyFromBase58(cfg.Recipient)
	recipientATA, _ := solanatx.FindAssociatedTokenAddressWithProgram(recipientKey, mint, solana.TokenProgramID)

	subscribeIx := subscriptions.BuildSubscribeIx(program, subscriptions.SubscribeAccounts{
		Subscriber: subscriber.PublicKey(), Merchant: puller, PlanPDA: planPDA,
		SubscriptionPDA: subscriptionPDA, SubscriptionAuthorityPDA: subscriptionAuthority, EventAuthority: eventAuthority,
	}, subscriptions.SubscribeData{PlanID: 1, PlanBump: 255, ExpectedMint: mint, ExpectedAmount: 10_000_000, ExpectedPeriodHours: 720, ExpectedCreatedAt: 1_700_000_000})
	transferIx := subscriptions.BuildTransferSubscriptionIx(program, subscriptions.TransferSubscriptionAccounts{
		SubscriptionPDA: subscriptionPDA, PlanPDA: planPDA, SubscriptionAuthority: subscriptionAuthority,
		DelegatorATA: subscriberATA, ReceiverATA: recipientATA, Caller: puller, TokenMint: mint,
		TokenProgram: solana.TokenProgramID, EventAuthority: eventAuthority,
	}, subscriptions.TransferData{Amount: 10_000_000, Delegator: subscriber.PublicKey(), Mint: mint})

	payer := subscriber.PublicKey()
	if useFeePayer {
		payer = feePayer
	}
	tx, err := solana.NewTransaction([]solana.Instruction{subscribeIx, transferIx}, blockhash, solana.TransactionPayer(payer))
	if err != nil {
		t.Fatal(err)
	}
	if err := solanatx.SignTransaction(tx, subscriber); err != nil {
		t.Fatal(err)
	}
	encoded, err := solanatx.EncodeTransactionBase64(tx)
	if err != nil {
		t.Fatal(err)
	}
	return activationFixture{subscriber: subscriber, subscriptionPDA: subscriptionPDA, encodedTx: encoded}
}

func termsConfig(t *testing.T) SubscriptionConfig {
	cfg := makeSubscriptionConfig(t)
	num := uint64(1)
	bump := uint8(255)
	created := int64(1_700_000_000)
	cfg.PlanIDNumeric = &num
	cfg.PlanBump = &bump
	cfg.PlanCreatedAt = &created
	return cfg
}

func delegationBytesFor(fix activationFixture, planPDA solana.PublicKey, amount, periodHours, amountPulled uint64, periodStart int64) []byte {
	var subBytes, planBytes [32]byte
	copy(subBytes[:], fix.subscriber.PublicKey().Bytes())
	copy(planBytes[:], planPDA.Bytes())
	return buildDelegationData(subBytes, planBytes, amount, periodHours, amountPulled, periodStart)
}

func TestVerifyCredentialAmountMismatch(t *testing.T) {
	cfg := termsConfig(t)
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	fix := buildActivationFixture(t, cfg, server, stub.Blockhash, solana.PublicKey{}, false)
	planPDA := solana.MustPublicKeyFromBase58(cfg.PlanID)
	stub.delegationPDA = fix.subscriptionPDA.String()
	// Delegation amount diverges from the 10_000_000 challenge terms.
	stub.delegationData = delegationBytesFor(fix, planPDA, 9_000_000, 720, 9_000_000, 1_700_000_000)

	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: fix.encodedTx})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = server.VerifyCredential(context.Background(), credential)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "amount mismatch") {
		t.Fatalf("expected amount mismatch, got %v", err)
	}
}

func TestVerifyCredentialPeriodMismatch(t *testing.T) {
	cfg := termsConfig(t)
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	fix := buildActivationFixture(t, cfg, server, stub.Blockhash, solana.PublicKey{}, false)
	planPDA := solana.MustPublicKeyFromBase58(cfg.PlanID)
	stub.delegationPDA = fix.subscriptionPDA.String()
	stub.delegationData = delegationBytesFor(fix, planPDA, 10_000_000, 168, 10_000_000, 1_700_000_000)

	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: fix.encodedTx})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = server.VerifyCredential(context.Background(), credential)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "period mismatch") {
		t.Fatalf("expected period mismatch, got %v", err)
	}
}

func TestVerifyCredentialPlanMismatch(t *testing.T) {
	cfg := termsConfig(t)
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	fix := buildActivationFixture(t, cfg, server, stub.Blockhash, solana.PublicKey{}, false)
	stub.delegationPDA = fix.subscriptionPDA.String()
	// Seed a delegation whose plan PDA differs from the configured plan.
	otherPlan := testutil.NewPrivateKey().PublicKey()
	stub.delegationData = delegationBytesFor(fix, otherPlan, 10_000_000, 720, 10_000_000, 1_700_000_000)

	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: fix.encodedTx})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = server.VerifyCredential(context.Background(), credential)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "plan mismatch") {
		t.Fatalf("expected plan mismatch, got %v", err)
	}
}

func TestVerifyCredentialNoFirstPeriodCharge(t *testing.T) {
	cfg := termsConfig(t)
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	fix := buildActivationFixture(t, cfg, server, stub.Blockhash, solana.PublicKey{}, false)
	planPDA := solana.MustPublicKeyFromBase58(cfg.PlanID)
	stub.delegationPDA = fix.subscriptionPDA.String()
	// amount_pulled = 0 means the activation tx did not pull the first period.
	stub.delegationData = delegationBytesFor(fix, planPDA, 10_000_000, 720, 0, 1_700_000_000)

	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: fix.encodedTx})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = server.VerifyCredential(context.Background(), credential)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "first-period charge") {
		t.Fatalf("expected first-period charge error, got %v", err)
	}
}

// existingDelegationRPC always returns the delegation account, so the
// idempotent guard skips the broadcast entirely.
type existingDelegationRPC struct {
	*testutil.FakeRPC
	delegationPDA  string
	delegationData []byte
}

func (s *existingDelegationRPC) GetAccountInfoWithOpts(_ context.Context, account solana.PublicKey, _ *rpc.GetAccountInfoOpts) (*rpc.GetAccountInfoResult, error) {
	if account.String() == s.delegationPDA {
		return &rpc.GetAccountInfoResult{
			Value: &rpc.Account{Data: rpc.DataBytesOrJSONFromBytes(s.delegationData)},
		}, nil
	}
	return nil, rpc.ErrNotFound
}

func TestVerifyCredentialIdempotentSkipsBroadcast(t *testing.T) {
	cfg := termsConfig(t)
	stub := &existingDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	fix := buildActivationFixture(t, cfg, server, stub.Blockhash, solana.PublicKey{}, false)
	planPDA := solana.MustPublicKeyFromBase58(cfg.PlanID)
	stub.delegationPDA = fix.subscriptionPDA.String()
	stub.delegationData = delegationBytesFor(fix, planPDA, 10_000_000, 720, 10_000_000, 1_700_000_000)

	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: fix.encodedTx})
	if err != nil {
		t.Fatal(err)
	}
	receipt, ext, err := server.VerifyCredential(context.Background(), credential)
	if err != nil {
		t.Fatalf("idempotent verify: %v", err)
	}
	if receipt.Status != core.ReceiptStatusSuccess {
		t.Errorf("status = %s", receipt.Status)
	}
	if len(stub.Sent) != 0 {
		t.Errorf("existing delegation must skip broadcast, sent = %d", len(stub.Sent))
	}
	if ext.ActivationSignature != "" {
		t.Errorf("idempotent path must report empty activation signature, got %q", ext.ActivationSignature)
	}
}

func TestVerifyCredentialFeePayerCoSigns(t *testing.T) {
	cfg := termsConfig(t)
	feePayer := testutil.NewPrivateKey()
	cfg.FeePayer = true
	cfg.FeePayerSigner = feePayer
	cfg.FeePayerKey = feePayer.PublicKey().String()
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	fix := buildActivationFixture(t, cfg, server, stub.Blockhash, feePayer.PublicKey(), true)
	planPDA := solana.MustPublicKeyFromBase58(cfg.PlanID)
	stub.delegationPDA = fix.subscriptionPDA.String()
	stub.delegationData = delegationBytesFor(fix, planPDA, 10_000_000, 720, 10_000_000, 1_700_000_000)

	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: fix.encodedTx})
	if err != nil {
		t.Fatal(err)
	}
	receipt, _, err := server.VerifyCredential(context.Background(), credential)
	if err != nil {
		t.Fatalf("fee-payer verify: %v", err)
	}
	if receipt.Status != core.ReceiptStatusSuccess {
		t.Errorf("status = %s", receipt.Status)
	}
	if len(stub.Sent) != 1 {
		t.Fatalf("broadcast count = %d, want 1", len(stub.Sent))
	}
	// The broadcast tx must carry the fee-payer signature in slot 0.
	sent := stub.Sent[0]
	if sent.Signatures[0].IsZero() {
		t.Error("fee payer signature slot is empty after co-sign")
	}
}

func TestVerifyCredentialFeePayerSignatureModeRejected(t *testing.T) {
	cfg := termsConfig(t)
	feePayer := testutil.NewPrivateKey()
	cfg.FeePayer = true
	cfg.FeePayerSigner = feePayer
	cfg.FeePayerKey = feePayer.PublicKey().String()
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "signature", Signature: "5J8Sig"})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.VerifyCredential(context.Background(), credential); err == nil {
		t.Fatal("signature mode with fee sponsorship must reject")
	}
}

func TestVerifyCredentialEmptyTransactionRejected(t *testing.T) {
	cfg := termsConfig(t)
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction"})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.VerifyCredential(context.Background(), credential); err == nil {
		t.Fatal("empty transaction field must reject")
	}
}

func TestVerifyCredentialUnsupportedPayloadTypeRejected(t *testing.T) {
	cfg := termsConfig(t)
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "bogus", Transaction: "AQAAAA=="})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.VerifyCredential(context.Background(), credential); err == nil {
		t.Fatal("unsupported payload type must reject")
	}
}

// ── verifyChallengeAndDecode mismatch branches ───────────────────────────

func issuedSubscriptionCredential(t *testing.T, server *SubscriptionServer, mutate func(*intents.SubscriptionRequest)) core.PaymentCredential {
	t.Helper()
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	var request intents.SubscriptionRequest
	if err := challenge.Request.Decode(&request); err != nil {
		t.Fatal(err)
	}
	mutate(&request)
	encoded, err := core.NewBase64URLJSONValue(request)
	if err != nil {
		t.Fatal(err)
	}
	// Re-issue the challenge under the server secret so HMAC passes and only the
	// mutated body field triggers a downstream mismatch.
	reissued := core.NewChallengeWithSecret(server.secretKey, server.realm,
		core.NewMethodName(subscriptionMethodName), core.NewIntentName(subscriptionIntentName), encoded)
	credential, err := core.NewPaymentCredential(reissued.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: "AQAAAA=="})
	if err != nil {
		t.Fatal(err)
	}
	return credential
}

func TestVerifyChallengeMintMismatch(t *testing.T) {
	server, err := NewSubscriptionServer(makeSubscriptionConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	credential := issuedSubscriptionCredential(t, server, func(r *intents.SubscriptionRequest) {
		r.Currency = testutil.NewPrivateKey().PublicKey().String()
	})
	_, err = server.verifyChallengeAndDecode(credential)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "mint") {
		t.Fatalf("expected mint mismatch, got %v", err)
	}
}

func TestVerifyChallengeRecipientMismatch(t *testing.T) {
	server, err := NewSubscriptionServer(makeSubscriptionConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	credential := issuedSubscriptionCredential(t, server, func(r *intents.SubscriptionRequest) {
		r.Recipient = testutil.NewPrivateKey().PublicKey().String()
	})
	_, err = server.verifyChallengeAndDecode(credential)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "recipient") {
		t.Fatalf("expected recipient mismatch, got %v", err)
	}
}

func TestVerifyChallengeRealmMismatch(t *testing.T) {
	server, err := NewSubscriptionServer(makeSubscriptionConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	var request intents.SubscriptionRequest
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	if err := challenge.Request.Decode(&request); err != nil {
		t.Fatal(err)
	}
	encoded, err := core.NewBase64URLJSONValue(request)
	if err != nil {
		t.Fatal(err)
	}
	// Same secret, different realm: HMAC over the realm still passes Verify, but
	// the realm check downstream rejects.
	reissued := core.NewChallengeWithSecret(server.secretKey, "Some Other Realm",
		core.NewMethodName(subscriptionMethodName), core.NewIntentName(subscriptionIntentName), encoded)
	credential, err := core.NewPaymentCredential(reissued.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: "AQAAAA=="})
	if err != nil {
		t.Fatal(err)
	}
	_, err = server.verifyChallengeAndDecode(credential)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "realm") {
		t.Fatalf("expected realm mismatch, got %v", err)
	}
}

func TestVerifyChallengeIntentMismatch(t *testing.T) {
	server, err := NewSubscriptionServer(makeSubscriptionConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	var request intents.SubscriptionRequest
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	if err := challenge.Request.Decode(&request); err != nil {
		t.Fatal(err)
	}
	encoded, err := core.NewBase64URLJSONValue(request)
	if err != nil {
		t.Fatal(err)
	}
	// A charge intent under the same secret/realm fails the subscription-intent guard.
	reissued := core.NewChallengeWithSecret(server.secretKey, server.realm,
		core.NewMethodName(subscriptionMethodName), core.NewIntentName("charge"), encoded)
	credential, err := core.NewPaymentCredential(reissued.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: "AQAAAA=="})
	if err != nil {
		t.Fatal(err)
	}
	_, err = server.verifyChallengeAndDecode(credential)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "subscription") {
		t.Fatalf("expected intent mismatch, got %v", err)
	}
}

func TestVerifyChallengeMethodMismatch(t *testing.T) {
	server, err := NewSubscriptionServer(makeSubscriptionConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	var request intents.SubscriptionRequest
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	if err := challenge.Request.Decode(&request); err != nil {
		t.Fatal(err)
	}
	encoded, err := core.NewBase64URLJSONValue(request)
	if err != nil {
		t.Fatal(err)
	}
	reissued := core.NewChallengeWithSecret(server.secretKey, server.realm,
		core.NewMethodName("evm"), core.NewIntentName(subscriptionIntentName), encoded)
	credential, err := core.NewPaymentCredential(reissued.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: "AQAAAA=="})
	if err != nil {
		t.Fatal(err)
	}
	_, err = server.verifyChallengeAndDecode(credential)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "method") {
		t.Fatalf("expected method mismatch, got %v", err)
	}
}

func TestSubscriptionChallengeFeePayerSignerFallback(t *testing.T) {
	cfg := makeSubscriptionConfig(t)
	feePayer := testutil.NewPrivateKey()
	cfg.FeePayer = true
	cfg.FeePayerSigner = feePayer
	// FeePayerKey omitted: the challenge must fall back to the signer's pubkey.
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	var request intents.SubscriptionRequest
	if err := challenge.Request.Decode(&request); err != nil {
		t.Fatal(err)
	}
	md, err := paycore.SubscriptionMethodDetailsFromValue(request.MethodDetails)
	if err != nil {
		t.Fatal(err)
	}
	if !md.FeePayer || md.FeePayerKey != feePayer.PublicKey().String() {
		t.Fatalf("feePayerKey = %q, want signer pubkey %s", md.FeePayerKey, feePayer.PublicKey())
	}
}

func TestVerifyChallengeExpiredRejected(t *testing.T) {
	server, err := NewSubscriptionServer(makeSubscriptionConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	body := intents.SubscriptionRequest{
		Amount: "10000000", Currency: server.Mint(), PeriodUnit: intents.PeriodUnitDay,
		PeriodCount: "30", Recipient: server.Recipient(),
	}
	encoded, err := core.NewBase64URLJSONValue(body)
	if err != nil {
		t.Fatal(err)
	}
	// HMAC-valid challenge that already expired in the past.
	expired := core.NewChallengeWithSecretFull(server.secretKey, server.realm,
		core.NewMethodName(subscriptionMethodName), core.NewIntentName(subscriptionIntentName),
		encoded, "2000-01-01T00:00:00Z", "", "", nil)
	credential, err := core.NewPaymentCredential(expired.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: "AQAAAA=="})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.VerifyCredential(context.Background(), credential); err == nil ||
		!strings.Contains(strings.ToLower(err.Error()), "expired") {
		t.Fatalf("expected challenge expired, got %v", err)
	}
}

func TestVerifyCredentialBroadcastFailureRejected(t *testing.T) {
	cfg := termsConfig(t)
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	stub.SendErr = errors.New("rpc rejected broadcast")
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	fix := buildActivationFixture(t, cfg, server, stub.Blockhash, solana.PublicKey{}, false)
	stub.delegationPDA = fix.subscriptionPDA.String()
	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: fix.encodedTx})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.VerifyCredential(context.Background(), credential); err == nil ||
		!strings.Contains(strings.ToLower(err.Error()), "broadcast") {
		t.Fatalf("expected broadcast failure, got %v", err)
	}
}

// failConfirmRPC lands the broadcast but reports the signature as failed on
// chain, exercising the confirmation-failure branch.
type failConfirmRPC struct {
	*stubDelegationRPC
}

func (f *failConfirmRPC) SendTransactionWithOpts(ctx context.Context, tx *solana.Transaction, opts rpc.TransactionOpts) (solana.Signature, error) {
	sig, err := f.stubDelegationRPC.SendTransactionWithOpts(ctx, tx, opts)
	if err == nil {
		f.Statuses[sig.String()] = &rpc.SignatureStatusesResult{
			Err:                "InstructionError",
			ConfirmationStatus: rpc.ConfirmationStatusConfirmed,
		}
	}
	return sig, err
}

func TestVerifyCredentialConfirmationFailureRejected(t *testing.T) {
	cfg := termsConfig(t)
	base := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	stub := &failConfirmRPC{stubDelegationRPC: base}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	fix := buildActivationFixture(t, cfg, server, base.Blockhash, solana.PublicKey{}, false)
	base.delegationPDA = fix.subscriptionPDA.String()
	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: fix.encodedTx})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.VerifyCredential(context.Background(), credential); err == nil ||
		!strings.Contains(strings.ToLower(err.Error()), "confirm") {
		t.Fatalf("expected confirmation failure, got %v", err)
	}
}

func TestExtractSubscriberFromTxEmptyKeysRejected(t *testing.T) {
	tx := &solana.Transaction{}
	cfg := SubscriptionConfig{Puller: testutil.NewPrivateKey().PublicKey().String()}
	if _, err := extractSubscriberFromTx(tx, cfg, nil); err == nil {
		t.Fatal("empty account keys must error")
	}
}

func TestExtractSubscriberFromTxInvalidPullerRejected(t *testing.T) {
	tx := &solana.Transaction{
		Message: solana.Message{AccountKeys: []solana.PublicKey{testutil.NewPrivateKey().PublicKey()}},
	}
	cfg := SubscriptionConfig{Puller: "not-a-pubkey"}
	if _, err := extractSubscriberFromTx(tx, cfg, nil); err == nil {
		t.Fatal("invalid puller pubkey must error")
	}
}

func TestExtractSubscriberFromTxInvalidFeePayerKeyRejected(t *testing.T) {
	puller := testutil.NewPrivateKey().PublicKey()
	tx := &solana.Transaction{
		Message: solana.Message{AccountKeys: []solana.PublicKey{puller, testutil.NewPrivateKey().PublicKey()}},
	}
	cfg := SubscriptionConfig{Puller: puller.String(), FeePayer: true, FeePayerKey: "not-a-pubkey"}
	if _, err := extractSubscriberFromTx(tx, cfg, nil); err == nil {
		t.Fatal("invalid fee payer key must error")
	}
}

func TestVerifyCredentialSimulationFailureRejected(t *testing.T) {
	cfg := termsConfig(t)
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	stub.SimulateErr = errors.New("simulated revert")
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	fix := buildActivationFixture(t, cfg, server, stub.Blockhash, solana.PublicKey{}, false)
	stub.delegationPDA = fix.subscriptionPDA.String()

	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: fix.encodedTx})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.VerifyCredential(context.Background(), credential); err == nil ||
		!strings.Contains(strings.ToLower(err.Error()), "simulate") {
		t.Fatalf("expected simulation failure, got %v", err)
	}
}

func TestVerifyCredentialUndecodableTransactionRejected(t *testing.T) {
	cfg := termsConfig(t)
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	// Valid base64 that is not a valid transaction wire form.
	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: "AQAAAA=="})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.VerifyCredential(context.Background(), credential); err == nil {
		t.Fatal("undecodable transaction must reject")
	}
}

func TestVerifyCredentialGarbagePayloadRejected(t *testing.T) {
	cfg := termsConfig(t)
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	credential, err := core.NewPaymentCredential(challenge.ToEcho(), map[string]any{"unrelated": "object"})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.VerifyCredential(context.Background(), credential); err == nil {
		t.Fatal("garbage activation payload must reject")
	}
}

func TestVerifyCredentialActivationScopeViolationRejected(t *testing.T) {
	cfg := termsConfig(t)
	stub := &stubDelegationRPC{FakeRPC: testutil.NewFakeRPC()}
	cfg.RPC = stub
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	// A transaction with only a memo (no subscribe/transfer) fails the scope guard.
	memoIx := solana.NewInstruction(
		solana.MustPublicKeyFromBase58(paycore.MemoProgram),
		nil, []byte("noop"),
	)
	subscriber := testutil.NewPrivateKey()
	tx, err := solana.NewTransaction([]solana.Instruction{memoIx}, stub.Blockhash, solana.TransactionPayer(subscriber.PublicKey()))
	if err != nil {
		t.Fatal(err)
	}
	if err := solanatx.SignTransaction(tx, subscriber); err != nil {
		t.Fatal(err)
	}
	encoded, err := solanatx.EncodeTransactionBase64(tx)
	if err != nil {
		t.Fatal(err)
	}
	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: encoded})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.VerifyCredential(context.Background(), credential); err == nil {
		t.Fatal("activation missing subscribe/transfer must reject")
	}
}

func TestValidateActivationScopeRejectsDuplicateInstructions(t *testing.T) {
	program := subscriptions.DefaultProgramID()
	subscriber := testutil.NewPrivateKey()
	puller := testutil.NewPrivateKey().PublicKey()
	eventAuthority, _, _ := subscriptions.FindEventAuthorityPDA(program)
	mint := solana.MustPublicKeyFromBase58(paycore.USDCMainnetMint)

	subscribeIx := subscriptions.BuildSubscribeIx(program, subscriptions.SubscribeAccounts{
		Subscriber: subscriber.PublicKey(), Merchant: puller, PlanPDA: testutil.NewPrivateKey().PublicKey(),
		SubscriptionPDA: testutil.NewPrivateKey().PublicKey(), SubscriptionAuthorityPDA: testutil.NewPrivateKey().PublicKey(),
		EventAuthority: eventAuthority,
	}, subscriptions.SubscribeData{PlanID: 1, PlanBump: 255, ExpectedMint: mint, ExpectedAmount: 1, ExpectedPeriodHours: 720})
	transferIx := subscriptions.BuildTransferSubscriptionIx(program, subscriptions.TransferSubscriptionAccounts{
		SubscriptionPDA: testutil.NewPrivateKey().PublicKey(), PlanPDA: testutil.NewPrivateKey().PublicKey(),
		SubscriptionAuthority: testutil.NewPrivateKey().PublicKey(), DelegatorATA: testutil.NewPrivateKey().PublicKey(),
		ReceiverATA: testutil.NewPrivateKey().PublicKey(), Caller: puller, TokenMint: mint,
		TokenProgram: solana.TokenProgramID, EventAuthority: eventAuthority,
	}, subscriptions.TransferData{Amount: 1, Delegator: subscriber.PublicKey(), Mint: mint})

	blockhash := testutil.NewFakeRPC().Blockhash

	dupSubscribe, err := solana.NewTransaction([]solana.Instruction{subscribeIx, subscribeIx, transferIx}, blockhash, solana.TransactionPayer(subscriber.PublicKey()))
	if err != nil {
		t.Fatal(err)
	}
	if err := validateActivationScope(dupSubscribe, subscriptions.SubscriptionsProgramID); err == nil ||
		!strings.Contains(err.Error(), "multiple subscribe") {
		t.Fatalf("duplicate subscribe must error, got %v", err)
	}

	dupTransfer, err := solana.NewTransaction([]solana.Instruction{subscribeIx, transferIx, transferIx}, blockhash, solana.TransactionPayer(subscriber.PublicKey()))
	if err != nil {
		t.Fatal(err)
	}
	if err := validateActivationScope(dupTransfer, subscriptions.SubscriptionsProgramID); err == nil ||
		!strings.Contains(err.Error(), "multiple transfer_subscription") {
		t.Fatalf("duplicate transfer must error, got %v", err)
	}
}

func TestValidateActivationScopeInvalidProgramIDErrors(t *testing.T) {
	tx := &solana.Transaction{}
	if err := validateActivationScope(tx, "not-a-pubkey"); err == nil {
		t.Fatal("invalid program id must error")
	}
}

func TestExtractSubscriberFromTxFeePayerNoSubscriberFound(t *testing.T) {
	feePayer := testutil.NewPrivateKey().PublicKey()
	puller := testutil.NewPrivateKey().PublicKey()
	// A transaction whose only non-fee-payer key is the puller leaves no
	// candidate subscriber, exercising the "could not identify" branch.
	tx := &solana.Transaction{
		Message: solana.Message{
			AccountKeys: []solana.PublicKey{feePayer, puller},
		},
	}
	cfg := SubscriptionConfig{Puller: puller.String(), FeePayer: true, FeePayerKey: feePayer.String()}
	if _, err := extractSubscriberFromTx(tx, cfg, nil); err == nil {
		t.Fatal("no identifiable subscriber must error")
	}
}
