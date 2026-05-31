package client

import (
	"context"
	"encoding/binary"
	"testing"

	solana "github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/rpc"

	"github.com/solana-foundation/pay-kit/go/internal/testutil"
	"github.com/solana-foundation/pay-kit/go/paycore"
	"github.com/solana-foundation/pay-kit/go/paycore/solanatx"
	"github.com/solana-foundation/pay-kit/go/paycore/subscriptions"
	core "github.com/solana-foundation/pay-kit/go/protocols/mpp/core"
)

// saAccountRPC returns a canned SubscriptionAuthority account so the activation
// builder reads init_id from RPC instead of taking the pinned shortcut.
type saAccountRPC struct {
	*testutil.FakeRPC
	saPubkey string
	saData   []byte
}

func (s *saAccountRPC) GetAccountInfoWithOpts(_ context.Context, account solana.PublicKey, _ *rpc.GetAccountInfoOpts) (*rpc.GetAccountInfoResult, error) {
	if account.String() == s.saPubkey {
		return &rpc.GetAccountInfoResult{
			Value: &rpc.Account{Data: rpc.DataBytesOrJSONFromBytes(s.saData)},
		}, nil
	}
	return nil, rpc.ErrNotFound
}

func pinnedInitID(id int64) *int64 { return &id }

func u64(v uint64) *uint64 { return &v }
func u8p(v uint8) *uint8   { return &v }
func i64p(v int64) *int64  { return &v }

func makeMethodDetails(t *testing.T, feePayer bool, feePayerKey string) paycore.SubscriptionMethodDetails {
	t.Helper()
	blockhash := testutil.NewFakeRPC().Blockhash.String()
	dec := uint8(6)
	puller := testutil.NewPrivateKey().PublicKey().String()
	return paycore.SubscriptionMethodDetails{
		PlanID:              testutil.NewPrivateKey().PublicKey().String(),
		Mint:                paycore.USDCMainnetMint,
		TokenProgram:        paycore.TokenProgram,
		Decimals:            &dec,
		Puller:              puller,
		Merchant:            puller,
		Recipient:           puller,
		Amount:              "10000000",
		Network:             "mainnet-beta",
		FeePayer:            feePayer,
		FeePayerKey:         feePayerKey,
		RecentBlockhash:     blockhash,
		PlanIDNumeric:       u64(1),
		PlanBump:            u8p(255),
		ExpectedPeriodHours: u64(720),
		ExpectedCreatedAt:   i64p(1_700_000_000),
	}
}

func decodePayloadTx(t *testing.T, payload paycore.CredentialPayload) *solana.Transaction {
	t.Helper()
	if payload.Type != "transaction" {
		t.Fatalf("payload type = %q, want transaction", payload.Type)
	}
	tx, err := solanatx.DecodeTransactionBase64(payload.Transaction)
	if err != nil {
		t.Fatal(err)
	}
	return tx
}

func TestBuildSubscriptionActivationWithPinnedInitID(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()
	md := makeMethodDetails(t, false, "")

	payload, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, rpcClient, md,
		SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
	)
	if err != nil {
		t.Fatal(err)
	}
	tx := decodePayloadTx(t, payload)
	// [compute_price, compute_limit, create_idempotent_ata, subscribe, transfer] = 5.
	if len(tx.Message.Instructions) != 5 {
		t.Fatalf("instruction count = %d, want 5", len(tx.Message.Instructions))
	}
}

func TestBuildSubscriptionActivationWithExternalIDMemo(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()
	md := makeMethodDetails(t, false, "")

	payload, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, rpcClient, md,
		SubscriptionActivationOptions{
			ExternalID:                  "order-42",
			ComputeUnitLimit:            123_456,
			ComputeUnitPrice:            1_000,
			SubscriptionAuthorityInitID: pinnedInitID(0),
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	tx := decodePayloadTx(t, payload)
	if len(tx.Message.Instructions) != 6 {
		t.Fatalf("instruction count = %d, want 6", len(tx.Message.Instructions))
	}
	last := tx.Message.Instructions[5]
	memoProgram := solana.MustPublicKeyFromBase58(paycore.MemoProgram)
	if !tx.Message.AccountKeys[last.ProgramIDIndex].Equals(memoProgram) {
		t.Fatal("last instruction must be a memo")
	}
	if string(last.Data) != "order-42" {
		t.Fatalf("memo data = %q, want order-42", string(last.Data))
	}
}

func TestBuildSubscriptionActivationFeePayerWithoutKeyErrors(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()
	md := makeMethodDetails(t, true, "")

	_, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, rpcClient, md,
		SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
	)
	if err == nil {
		t.Fatal("feePayer=true without feePayerKey must error")
	}
}

func TestBuildSubscriptionActivationFeePayerSetsFeePayerAccount(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()
	feePayer := testutil.NewPrivateKey().PublicKey()
	md := makeMethodDetails(t, true, feePayer.String())

	payload, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, rpcClient, md,
		SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
	)
	if err != nil {
		t.Fatal(err)
	}
	tx := decodePayloadTx(t, payload)
	if !tx.Message.AccountKeys[0].Equals(feePayer) {
		t.Fatalf("account_keys[0] = %s, want fee payer %s", tx.Message.AccountKeys[0], feePayer)
	}
}

func TestBuildSubscriptionActivationInvalidMintErrors(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()
	md := makeMethodDetails(t, false, "")
	md.Mint = "not-a-pubkey"

	_, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, rpcClient, md,
		SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
	)
	if err == nil {
		t.Fatal("invalid mint must error")
	}
}

func TestBuildSubscriptionActivationMissingSubscribeFieldErrors(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()
	md := makeMethodDetails(t, false, "")
	md.PlanIDNumeric = nil

	_, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, rpcClient, md,
		SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
	)
	if err == nil {
		t.Fatal("missing planIdNumeric must error")
	}
}

func TestBuildSubscriptionActivationHeaderEndToEnd(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()
	md := makeMethodDetails(t, false, "")

	// Hand-build a challenge that pins the methodDetails, mirroring what the
	// server emits, so the header path decodes it back.
	dec := uint8(6)
	num := uint64(1)
	bump := uint8(255)
	hours := uint64(720)
	created := int64(1_700_000_000)
	request := core.SubscriptionRequest{
		Amount:      "10000000",
		Currency:    md.Mint,
		PeriodUnit:  core.PeriodUnitDay,
		PeriodCount: "30",
		Recipient:   md.Recipient,
		ExternalID:  "order-9",
		MethodDetails: core.SubscriptionMethodDetails{
			PlanID: md.PlanID, Mint: md.Mint, TokenProgram: md.TokenProgram, Decimals: &dec,
			Puller: md.Puller, Merchant: md.Merchant, Recipient: md.Recipient, Amount: "10000000",
			RecentBlockhash: md.RecentBlockhash, PlanIDNumeric: &num, PlanBump: &bump,
			ExpectedPeriodHours: &hours, ExpectedCreatedAt: &created,
		},
	}
	encoded, err := core.NewBase64URLJSONValue(request)
	if err != nil {
		t.Fatal(err)
	}
	challenge := core.NewChallengeWithSecret("secret", "MPP Subscription",
		core.NewMethodName("solana"), core.NewIntentName("subscription"), encoded)

	header, err := BuildSubscriptionActivationHeader(
		context.Background(), signer, rpcClient, challenge,
		SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
	)
	if err != nil {
		t.Fatal(err)
	}
	credential, err := core.ParseAuthorization(header)
	if err != nil {
		t.Fatal(err)
	}
	var payload core.CredentialPayload
	if err := credential.PayloadAs(&payload); err != nil {
		t.Fatal(err)
	}
	if payload.Type != "transaction" || payload.Transaction == "" {
		t.Fatalf("unexpected payload %+v", payload)
	}
	// The challenge's externalId must flow into the memo, so the tx carries it.
	tx := decodePayloadTx(t, payload)
	memoProgram := solana.MustPublicKeyFromBase58(paycore.MemoProgram)
	found := false
	for _, ix := range tx.Message.Instructions {
		if tx.Message.AccountKeys[ix.ProgramIDIndex].Equals(memoProgram) && string(ix.Data) == "order-9" {
			found = true
		}
	}
	if !found {
		t.Fatal("challenge externalId did not flow into a memo instruction")
	}
}

func TestBuildSubscriptionActivationReadsInitIDFromExistingSA(t *testing.T) {
	signer := testutil.NewPrivateKey()
	md := makeMethodDetails(t, false, "")

	program := subscriptions.DefaultProgramID()
	mint := solana.MustPublicKeyFromBase58(md.Mint)
	sa, _, err := subscriptions.FindSubscriptionAuthorityPDA(signer.PublicKey(), mint, program)
	if err != nil {
		t.Fatal(err)
	}

	saData := make([]byte, subscriptionAuthorityAccountLen)
	const initID int64 = 42
	binary.LittleEndian.PutUint64(saData[subscriptionAuthorityInitIDOffset:], uint64(initID))

	stub := &saAccountRPC{FakeRPC: testutil.NewFakeRPC(), saPubkey: sa.String(), saData: saData}

	// No pinned init id: the builder must read it from the existing SA account.
	payload, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, stub, md, SubscriptionActivationOptions{},
	)
	if err != nil {
		t.Fatal(err)
	}
	tx := decodePayloadTx(t, payload)
	// Locate the subscribe instruction (discriminator 11) and read its trailing
	// init_id i64 to confirm the SA value flowed in.
	for _, ix := range tx.Message.Instructions {
		if !tx.Message.AccountKeys[ix.ProgramIDIndex].Equals(program) {
			continue
		}
		data := []byte(ix.Data)
		if len(data) == 0 || data[0] != subscriptions.InstructionSubscribe {
			continue
		}
		// Subscribe data trails with expected_subscription_authority_init_id (last 8 bytes).
		got := int64(binary.LittleEndian.Uint64(data[len(data)-8:]))
		if got != initID {
			t.Fatalf("subscribe init_id = %d, want %d", got, initID)
		}
		return
	}
	t.Fatal("subscribe instruction not found")
}

func TestParseSubscriptionAuthorityInitID(t *testing.T) {
	data := make([]byte, subscriptionAuthorityAccountLen)
	const want int64 = 1_234_567
	for i := 0; i < 8; i++ {
		data[subscriptionAuthorityInitIDOffset+i] = byte(uint64(want) >> (8 * i))
	}
	got, err := parseSubscriptionAuthorityInitID(data)
	if err != nil || got != want {
		t.Fatalf("init_id = %d, err = %v; want %d", got, err, want)
	}
	if _, err := parseSubscriptionAuthorityInitID(make([]byte, 10)); err == nil {
		t.Fatal("wrong-length SA account must error")
	}
}

func TestBuildSubscriptionActivationSignedBySubscriber(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()
	md := makeMethodDetails(t, false, "")

	payload, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, rpcClient, md,
		SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
	)
	if err != nil {
		t.Fatal(err)
	}
	tx := decodePayloadTx(t, payload)
	idx := -1
	for i, k := range tx.Message.AccountKeys {
		if k.Equals(signer.PublicKey()) {
			idx = i
			break
		}
	}
	if idx < 0 {
		t.Fatal("subscriber not in account keys")
	}
	if tx.Signatures[idx].IsZero() {
		t.Fatal("subscriber signature slot is empty")
	}
}
