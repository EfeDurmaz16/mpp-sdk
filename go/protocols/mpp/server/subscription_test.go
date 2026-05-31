package server

import (
	"context"
	"encoding/binary"
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

func makeSubscriptionConfig(t *testing.T) SubscriptionConfig {
	t.Helper()
	return SubscriptionConfig{
		PlanID:       testutil.NewPrivateKey().PublicKey().String(),
		Mint:         paycore.USDCMainnetMint,
		TokenProgram: paycore.TokenProgram,
		Puller:       testutil.NewPrivateKey().PublicKey().String(),
		Recipient:    testutil.NewPrivateKey().PublicKey().String(),
		SecretKey:    "test-secret",
	}
}

func TestNewSubscriptionServerRejectsMissingFields(t *testing.T) {
	cases := map[string]func(*SubscriptionConfig){
		"plan_id":       func(c *SubscriptionConfig) { c.PlanID = "" },
		"mint":          func(c *SubscriptionConfig) { c.Mint = "" },
		"token_program": func(c *SubscriptionConfig) { c.TokenProgram = "" },
		"puller":        func(c *SubscriptionConfig) { c.Puller = "" },
		"recipient":     func(c *SubscriptionConfig) { c.Recipient = "" },
	}
	for field, mutate := range cases {
		cfg := makeSubscriptionConfig(t)
		mutate(&cfg)
		_, err := NewSubscriptionServer(cfg)
		if err == nil || !strings.Contains(err.Error(), field) {
			t.Errorf("missing %s: got err = %v", field, err)
		}
	}
}

func TestNewSubscriptionServerRejectsInvalidPubkey(t *testing.T) {
	cfg := makeSubscriptionConfig(t)
	cfg.PlanID = "not-a-pubkey"
	if _, err := NewSubscriptionServer(cfg); err == nil {
		t.Fatal("invalid plan_id pubkey must error")
	}
}

func TestNewSubscriptionServerRejectsOutOfRangePeriod(t *testing.T) {
	cfg := makeSubscriptionConfig(t)
	cfg.PeriodUnit = intents.PeriodUnitDay
	cfg.PeriodCount = 400
	if _, err := NewSubscriptionServer(cfg); err == nil {
		t.Fatal("period_count 400 must error")
	}
}

func TestNewSubscriptionServerRequiresSecret(t *testing.T) {
	cfg := makeSubscriptionConfig(t)
	cfg.SecretKey = ""
	t.Setenv("MPP_SECRET_KEY", "")
	if _, err := NewSubscriptionServer(cfg); err == nil {
		t.Fatal("missing secret must error")
	}
}

func TestSubscriptionServerAccessors(t *testing.T) {
	cfg := makeSubscriptionConfig(t)
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if server.Realm() != defaultSubscriptionRealm {
		t.Errorf("realm = %s", server.Realm())
	}
	if server.PlanID() != cfg.PlanID || server.Mint() != cfg.Mint {
		t.Error("plan/mint accessor mismatch")
	}
	if server.Puller() != cfg.Puller || server.Recipient() != cfg.Recipient {
		t.Error("puller/recipient accessor mismatch")
	}
	if server.ProgramID() != subscriptions.SubscriptionsProgramID {
		t.Errorf("program id = %s", server.ProgramID())
	}
	if server.PeriodUnit() != intents.PeriodUnitDay || server.PeriodCount() != 30 {
		t.Errorf("period defaults = %s/%d", server.PeriodUnit(), server.PeriodCount())
	}
}

func TestSubscriptionChallengeWellFormed(t *testing.T) {
	server, err := NewSubscriptionServer(makeSubscriptionConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "10000000")
	if err != nil {
		t.Fatal(err)
	}
	header, err := core.FormatWWWAuthenticate(challenge)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`intent="subscription"`, `method="solana"`, `realm="MPP Subscription"`} {
		if !strings.Contains(header, want) {
			t.Errorf("header missing %s: %s", want, header)
		}
	}
}

func TestSubscriptionChallengeEncodesPeriodAndPlan(t *testing.T) {
	cfg := makeSubscriptionConfig(t)
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
	if request.PeriodUnit != intents.PeriodUnitDay || request.PeriodCount != "30" {
		t.Errorf("period = %s/%s", request.PeriodUnit, request.PeriodCount)
	}
	md, err := paycore.SubscriptionMethodDetailsFromValue(request.MethodDetails)
	if err != nil {
		t.Fatal(err)
	}
	if md.PlanID != cfg.PlanID {
		t.Errorf("methodDetails.planId = %s, want %s", md.PlanID, cfg.PlanID)
	}
	if md.ExpectedPeriodHours == nil || *md.ExpectedPeriodHours != 720 {
		t.Errorf("expectedPeriodHours = %v", md.ExpectedPeriodHours)
	}
}

func TestSubscriptionChallengeRejectsInvalidAmount(t *testing.T) {
	server, err := NewSubscriptionServer(makeSubscriptionConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := server.SubscriptionChallenge(context.Background(), "not-a-number"); err == nil {
		t.Error("invalid amount must error")
	}
	if _, err := server.SubscriptionChallenge(context.Background(), ""); err == nil {
		t.Error("empty amount must error")
	}
}

func TestSubscriptionChallengeWeekRoundTrip(t *testing.T) {
	cfg := makeSubscriptionConfig(t)
	cfg.PeriodUnit = intents.PeriodUnitWeek
	cfg.PeriodCount = 2
	server, err := NewSubscriptionServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := server.SubscriptionChallenge(context.Background(), "5000000")
	if err != nil {
		t.Fatal(err)
	}
	var request intents.SubscriptionRequest
	if err := challenge.Request.Decode(&request); err != nil {
		t.Fatal(err)
	}
	if request.PeriodUnit != intents.PeriodUnitWeek || request.PeriodCount != "2" {
		t.Errorf("week round-trip = %s/%s", request.PeriodUnit, request.PeriodCount)
	}
}

func TestVerifyCredentialRejectsHMACMismatch(t *testing.T) {
	server, err := NewSubscriptionServer(makeSubscriptionConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	// Build a challenge with a different secret so HMAC fails.
	body := intents.SubscriptionRequest{
		Amount: "1", Currency: server.Mint(), PeriodUnit: intents.PeriodUnitDay,
		PeriodCount: "30", Recipient: server.Recipient(),
	}
	encoded, err := core.NewBase64URLJSONValue(body)
	if err != nil {
		t.Fatal(err)
	}
	bad := core.NewChallengeWithSecret("other-secret", "MPP Subscription",
		core.NewMethodName("solana"), core.NewIntentName("subscription"), encoded)
	credential, err := core.NewPaymentCredential(bad.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: "AQAAAA=="})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = server.VerifyCredential(context.Background(), credential)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "hmac") {
		t.Fatalf("expected HMAC mismatch, got %v", err)
	}
}

func TestVerifyCredentialRejectsPushModeV0(t *testing.T) {
	server, err := NewSubscriptionServer(makeSubscriptionConfig(t))
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
	_, _, err = server.VerifyCredential(context.Background(), credential)
	if err == nil {
		t.Fatal("v0 must reject push mode")
	}
	msg := strings.ToLower(err.Error())
	if !strings.Contains(msg, "push-mode") && !strings.Contains(msg, "not yet supported") {
		t.Fatalf("unexpected error %v", err)
	}
}

// ── Pure helper golden-vector tests ──────────────────────────────────────

func buildDelegationData(subscriber, planPDA [32]byte, amount, periodHours, amountPulled uint64, periodStart int64) []byte {
	data := make([]byte, 0, subscriptionDelegationLen)
	data = append(data, 2, 1, 255) // discriminator, version, bump
	data = append(data, subscriber[:]...)
	data = append(data, planPDA[:]...)
	data = append(data, make([]byte, 32)...)     // payer
	data = appendLE(data, uint64(77))            // init_id
	data = appendLE(data, amount)                // terms.amount
	data = appendLE(data, periodHours)           // terms.period_hours
	data = appendLE(data, uint64(1_780_000_000)) // terms.created_at
	data = appendLE(data, amountPulled)          // amount_pulled_in_period
	data = appendLE(data, uint64(periodStart))   // current_period_start_ts
	data = appendLE(data, 0)                     // expires_at_ts
	return data
}

func appendLE(buf []byte, v uint64) []byte {
	var b [8]byte
	binary.LittleEndian.PutUint64(b[:], v)
	return append(buf, b[:]...)
}

func TestDecodeSubscriptionDelegationReadsFields(t *testing.T) {
	var subscriber, planPDA [32]byte
	for i := range subscriber {
		subscriber[i] = 1
		planPDA[i] = 2
	}
	data := buildDelegationData(subscriber, planPDA, 9_990_000, 720, 9_990_000, 1_700_000_000)
	if len(data) != subscriptionDelegationLen {
		t.Fatalf("test data length = %d, want %d", len(data), subscriptionDelegationLen)
	}
	view, err := decodeSubscriptionDelegation(data)
	if err != nil {
		t.Fatal(err)
	}
	if view.AmountPerPeriod != 9_990_000 || view.PeriodHours != 720 {
		t.Errorf("terms = %d/%d", view.AmountPerPeriod, view.PeriodHours)
	}
	if view.CurrentPeriodStartTS != 1_700_000_000 || view.AmountPulledInPeriod != 9_990_000 {
		t.Errorf("period/pulled = %d/%d", view.CurrentPeriodStartTS, view.AmountPulledInPeriod)
	}
	if view.Subscriber.Bytes()[0] != 1 || view.PlanPDA.Bytes()[0] != 2 {
		t.Error("subscriber/plan bytes mismatch")
	}
}

func TestDecodeSubscriptionDelegationRejectsShort(t *testing.T) {
	if _, err := decodeSubscriptionDelegation(make([]byte, 50)); err == nil {
		t.Fatal("short data must error")
	}
}

func TestValidateActivationScopeRequiresBothInstructions(t *testing.T) {
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

	ok, err := solana.NewTransaction([]solana.Instruction{subscribeIx, transferIx}, blockhash, solana.TransactionPayer(subscriber.PublicKey()))
	if err != nil {
		t.Fatal(err)
	}
	if err := validateActivationScope(ok, subscriptions.SubscriptionsProgramID); err != nil {
		t.Fatalf("well-formed activation rejected: %v", err)
	}

	// Wrong order: transfer before subscribe.
	bad, err := solana.NewTransaction([]solana.Instruction{transferIx, subscribeIx}, blockhash, solana.TransactionPayer(subscriber.PublicKey()))
	if err != nil {
		t.Fatal(err)
	}
	if err := validateActivationScope(bad, subscriptions.SubscriptionsProgramID); err == nil {
		t.Fatal("transfer before subscribe must error")
	}

	// Missing transfer.
	missing, err := solana.NewTransaction([]solana.Instruction{subscribeIx}, blockhash, solana.TransactionPayer(subscriber.PublicKey()))
	if err != nil {
		t.Fatal(err)
	}
	if err := validateActivationScope(missing, subscriptions.SubscriptionsProgramID); err == nil {
		t.Fatal("missing transfer must error")
	}
}

func TestExtractSubscriberFromTxNoFeePayer(t *testing.T) {
	program := subscriptions.DefaultProgramID()
	subscriber := testutil.NewPrivateKey()
	puller := testutil.NewPrivateKey().PublicKey()
	eventAuthority, _, _ := subscriptions.FindEventAuthorityPDA(program)
	mint := solana.MustPublicKeyFromBase58(paycore.USDCMainnetMint)
	ix := subscriptions.BuildSubscribeIx(program, subscriptions.SubscribeAccounts{
		Subscriber: subscriber.PublicKey(), Merchant: puller, PlanPDA: testutil.NewPrivateKey().PublicKey(),
		SubscriptionPDA: testutil.NewPrivateKey().PublicKey(), SubscriptionAuthorityPDA: testutil.NewPrivateKey().PublicKey(),
		EventAuthority: eventAuthority,
	}, subscriptions.SubscribeData{PlanID: 1, PlanBump: 255, ExpectedMint: mint, ExpectedAmount: 1, ExpectedPeriodHours: 720})
	tx, err := solana.NewTransaction([]solana.Instruction{ix}, testutil.NewFakeRPC().Blockhash, solana.TransactionPayer(subscriber.PublicKey()))
	if err != nil {
		t.Fatal(err)
	}
	cfg := SubscriptionConfig{Puller: puller.String()}
	got, err := extractSubscriberFromTx(tx, cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Equals(subscriber.PublicKey()) {
		t.Fatalf("subscriber = %s, want %s", got, subscriber.PublicKey())
	}
}

func TestExtractSubscriberFromTxWithFeePayer(t *testing.T) {
	program := subscriptions.DefaultProgramID()
	subscriber := testutil.NewPrivateKey()
	feePayer := testutil.NewPrivateKey()
	puller := testutil.NewPrivateKey().PublicKey()
	eventAuthority, _, _ := subscriptions.FindEventAuthorityPDA(program)
	mint := solana.MustPublicKeyFromBase58(paycore.USDCMainnetMint)
	payerKey := feePayer.PublicKey()
	ix := subscriptions.BuildSubscribeIx(program, subscriptions.SubscribeAccounts{
		Subscriber: subscriber.PublicKey(), Merchant: puller, PlanPDA: testutil.NewPrivateKey().PublicKey(),
		SubscriptionPDA: testutil.NewPrivateKey().PublicKey(), SubscriptionAuthorityPDA: testutil.NewPrivateKey().PublicKey(),
		EventAuthority: eventAuthority, Payer: &payerKey,
	}, subscriptions.SubscribeData{PlanID: 1, PlanBump: 255, ExpectedMint: mint, ExpectedAmount: 1, ExpectedPeriodHours: 720})
	// Fee payer is the tx payer (account_keys[0]).
	tx, err := solana.NewTransaction([]solana.Instruction{ix}, testutil.NewFakeRPC().Blockhash, solana.TransactionPayer(feePayer.PublicKey()))
	if err != nil {
		t.Fatal(err)
	}
	cfg := SubscriptionConfig{Puller: puller.String(), FeePayer: true, FeePayerKey: feePayer.PublicKey().String()}
	got, err := extractSubscriberFromTx(tx, cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Equals(subscriber.PublicKey()) {
		t.Fatalf("subscriber = %s, want %s", got, subscriber.PublicKey())
	}
}

func TestExtractSubscriberFromTxRejectsPullerAsSubscriber(t *testing.T) {
	program := subscriptions.DefaultProgramID()
	puller := testutil.NewPrivateKey()
	eventAuthority, _, _ := subscriptions.FindEventAuthorityPDA(program)
	mint := solana.MustPublicKeyFromBase58(paycore.USDCMainnetMint)
	ix := subscriptions.BuildSubscribeIx(program, subscriptions.SubscribeAccounts{
		Subscriber: puller.PublicKey(), Merchant: puller.PublicKey(), PlanPDA: testutil.NewPrivateKey().PublicKey(),
		SubscriptionPDA: testutil.NewPrivateKey().PublicKey(), SubscriptionAuthorityPDA: testutil.NewPrivateKey().PublicKey(),
		EventAuthority: eventAuthority,
	}, subscriptions.SubscribeData{PlanID: 1, PlanBump: 255, ExpectedMint: mint, ExpectedAmount: 1, ExpectedPeriodHours: 720})
	tx, err := solana.NewTransaction([]solana.Instruction{ix}, testutil.NewFakeRPC().Blockhash, solana.TransactionPayer(puller.PublicKey()))
	if err != nil {
		t.Fatal(err)
	}
	cfg := SubscriptionConfig{Puller: puller.PublicKey().String()}
	if _, err := extractSubscriberFromTx(tx, cfg, nil); err == nil {
		t.Fatal("subscriber == puller must error")
	}
}

func TestDecodeActivatePayloadAcceptsRawAndWrapped(t *testing.T) {
	raw, err := core.NewPaymentCredential(core.ChallengeEcho{}, paycore.ActivatePayload{Type: "transaction", Transaction: "AQAAAA=="})
	if err != nil {
		t.Fatal(err)
	}
	got, err := decodeActivatePayload(raw)
	if err != nil || got.Type != "transaction" {
		t.Fatalf("raw decode: %+v err=%v", got, err)
	}

	wrapped, err := core.NewPaymentCredential(core.ChallengeEcho{}, paycore.SubscriptionAction{Action: "activate", Type: "transaction", Transaction: "AQAAAA=="})
	if err != nil {
		t.Fatal(err)
	}
	got, err = decodeActivatePayload(wrapped)
	if err != nil || got.Type != "transaction" {
		t.Fatalf("wrapped decode: %+v err=%v", got, err)
	}
}

func TestDecodeActivatePayloadRejectsGarbage(t *testing.T) {
	credential, err := core.NewPaymentCredential(core.ChallengeEcho{}, map[string]any{"random": "object"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeActivatePayload(credential); err == nil {
		t.Fatal("garbage payload must error")
	}
}

// stubDelegationRPC serves the delegation account data only after a broadcast
// has landed, mirroring the real flow where the activation transaction creates
// the SubscriptionDelegation PDA. The pre-broadcast existence probe sees
// NotFound, so the server takes the broadcast branch.
type stubDelegationRPC struct {
	*testutil.FakeRPC
	delegationPDA  string
	delegationData []byte
	broadcasted    bool
}

func (s *stubDelegationRPC) GetAccountInfoWithOpts(_ context.Context, account solana.PublicKey, _ *rpc.GetAccountInfoOpts) (*rpc.GetAccountInfoResult, error) {
	if account.String() == s.delegationPDA && s.broadcasted {
		return &rpc.GetAccountInfoResult{
			Value: &rpc.Account{Data: rpc.DataBytesOrJSONFromBytes(s.delegationData)},
		}, nil
	}
	return nil, rpc.ErrNotFound
}

func (s *stubDelegationRPC) SendTransactionWithOpts(ctx context.Context, tx *solana.Transaction, opts rpc.TransactionOpts) (solana.Signature, error) {
	s.broadcasted = true
	return s.FakeRPC.SendTransactionWithOpts(ctx, tx, opts)
}

func TestVerifyCredentialFullActivationFlow(t *testing.T) {
	cfg := makeSubscriptionConfig(t)
	num := uint64(1)
	bump := uint8(255)
	created := int64(1_700_000_000)
	cfg.PlanIDNumeric = &num
	cfg.PlanBump = &bump
	cfg.PlanCreatedAt = &created

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

	// Build an activation transaction matching the challenge terms.
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
	}, subscriptions.SubscribeData{PlanID: 1, PlanBump: 255, ExpectedMint: mint, ExpectedAmount: 10_000_000, ExpectedPeriodHours: 720, ExpectedCreatedAt: created})
	transferIx := subscriptions.BuildTransferSubscriptionIx(program, subscriptions.TransferSubscriptionAccounts{
		SubscriptionPDA: subscriptionPDA, PlanPDA: planPDA, SubscriptionAuthority: subscriptionAuthority,
		DelegatorATA: subscriberATA, ReceiverATA: recipientATA, Caller: puller, TokenMint: mint,
		TokenProgram: solana.TokenProgramID, EventAuthority: eventAuthority,
	}, subscriptions.TransferData{Amount: 10_000_000, Delegator: subscriber.PublicKey(), Mint: mint})

	tx, err := solana.NewTransaction([]solana.Instruction{subscribeIx, transferIx}, stub.Blockhash, solana.TransactionPayer(subscriber.PublicKey()))
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

	// Seed the delegation account that the post-broadcast fetch reads back.
	var subBytes, planBytes [32]byte
	copy(subBytes[:], subscriber.PublicKey().Bytes())
	copy(planBytes[:], planPDA.Bytes())
	stub.delegationPDA = subscriptionPDA.String()
	stub.delegationData = buildDelegationData(subBytes, planBytes, 10_000_000, 720, 10_000_000, 1_700_000_000)

	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.ActivatePayload{Type: "transaction", Transaction: encoded})
	if err != nil {
		t.Fatal(err)
	}
	receipt, ext, err := server.VerifyCredential(context.Background(), credential)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if receipt.Status != core.ReceiptStatusSuccess {
		t.Errorf("status = %s", receipt.Status)
	}
	if ext.SubscriptionID != subscriptionPDA.String() {
		t.Errorf("subscriptionId = %s, want %s", ext.SubscriptionID, subscriptionPDA)
	}
	if ext.PlanID != cfg.PlanID || ext.PeriodIndex != "0" {
		t.Errorf("plan/period = %s/%s", ext.PlanID, ext.PeriodIndex)
	}
	if ext.ActivationSignature == "" {
		t.Error("expected activation signature from broadcast")
	}
	if len(stub.Sent) != 1 {
		t.Errorf("broadcast count = %d, want 1", len(stub.Sent))
	}
}

func TestFormatRFC3339Seconds(t *testing.T) {
	if got := formatRFC3339Seconds(1_705_320_190); got != "2024-01-15T12:03:10Z" {
		t.Errorf("formatRFC3339Seconds = %s", got)
	}
	if got := formatRFC3339Seconds(0); got != "1970-01-01T00:00:00Z" {
		t.Errorf("epoch = %s", got)
	}
}
