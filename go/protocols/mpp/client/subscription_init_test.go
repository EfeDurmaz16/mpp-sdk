package client

import (
	"context"
	"encoding/binary"
	"errors"
	"testing"

	solana "github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/rpc"

	"github.com/solana-foundation/pay-kit/go/internal/testutil"
	"github.com/solana-foundation/pay-kit/go/paycore"
	"github.com/solana-foundation/pay-kit/go/paycore/subscriptions"
	core "github.com/solana-foundation/pay-kit/go/protocols/mpp/core"
)

// saInitRPC mirrors the live SubscriptionAuthority bootstrap: the PDA does not
// exist on the first GetAccountInfo probe, so the builder broadcasts the init
// transaction. After the broadcast lands, the PDA returns its serialized bytes
// carrying init_id, exercising the full ensureSubscriptionAuthorityInitID path.
type saInitRPC struct {
	*testutil.FakeRPC
	saPubkey  string
	saData    []byte
	broadcast bool
}

func (s *saInitRPC) GetAccountInfoWithOpts(_ context.Context, account solana.PublicKey, _ *rpc.GetAccountInfoOpts) (*rpc.GetAccountInfoResult, error) {
	if account.String() == s.saPubkey && s.broadcast {
		return &rpc.GetAccountInfoResult{
			Value: &rpc.Account{Data: rpc.DataBytesOrJSONFromBytes(s.saData)},
		}, nil
	}
	return nil, rpc.ErrNotFound
}

func (s *saInitRPC) SendTransactionWithOpts(ctx context.Context, tx *solana.Transaction, opts rpc.TransactionOpts) (solana.Signature, error) {
	s.broadcast = true
	return s.FakeRPC.SendTransactionWithOpts(ctx, tx, opts)
}

func saInitData(initID int64) []byte {
	data := make([]byte, subscriptionAuthorityAccountLen)
	binary.LittleEndian.PutUint64(data[subscriptionAuthorityInitIDOffset:], uint64(initID))
	return data
}

func TestBuildSubscriptionActivationBroadcastsInitWhenSAMissing(t *testing.T) {
	signer := testutil.NewPrivateKey()
	md := makeMethodDetails(t, false, "")

	program := subscriptions.DefaultProgramID()
	mint := solana.MustPublicKeyFromBase58(md.Mint)
	sa, _, err := subscriptions.FindSubscriptionAuthorityPDA(signer.PublicKey(), mint, program)
	if err != nil {
		t.Fatal(err)
	}

	const initID int64 = 99
	stub := &saInitRPC{FakeRPC: testutil.NewFakeRPC(), saPubkey: sa.String(), saData: saInitData(initID)}

	payload, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, stub, md, SubscriptionActivationOptions{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !stub.broadcast {
		t.Fatal("missing SA must trigger an init broadcast")
	}
	if len(stub.Sent) != 1 {
		t.Fatalf("init broadcast count = %d, want 1", len(stub.Sent))
	}

	tx := decodePayloadTx(t, payload)
	for _, ix := range tx.Message.Instructions {
		if !tx.Message.AccountKeys[ix.ProgramIDIndex].Equals(program) {
			continue
		}
		data := []byte(ix.Data)
		if len(data) == 0 || data[0] != subscriptions.InstructionSubscribe {
			continue
		}
		got := int64(binary.LittleEndian.Uint64(data[len(data)-8:]))
		if got != initID {
			t.Fatalf("subscribe init_id = %d, want %d (read from freshly-initialized SA)", got, initID)
		}
		return
	}
	t.Fatal("subscribe instruction not found")
}

// failSendRPC keeps the SA missing and fails the init broadcast so the
// ensureSubscriptionAuthorityInitID error wrapper is exercised.
type failSendRPC struct {
	*testutil.FakeRPC
}

func (f *failSendRPC) GetAccountInfoWithOpts(_ context.Context, _ solana.PublicKey, _ *rpc.GetAccountInfoOpts) (*rpc.GetAccountInfoResult, error) {
	return nil, rpc.ErrNotFound
}

func (f *failSendRPC) SendTransactionWithOpts(_ context.Context, _ *solana.Transaction, _ rpc.TransactionOpts) (solana.Signature, error) {
	return solana.Signature{}, errors.New("simulated send failure")
}

func TestBuildSubscriptionActivationInitBroadcastFailureErrors(t *testing.T) {
	signer := testutil.NewPrivateKey()
	md := makeMethodDetails(t, false, "")
	stub := &failSendRPC{FakeRPC: testutil.NewFakeRPC()}

	_, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, stub, md, SubscriptionActivationOptions{},
	)
	if err == nil {
		t.Fatal("init broadcast failure must propagate")
	}
}

// missingAfterInitRPC reports the SA missing on every GetAccountInfo, including
// the post-broadcast read, exercising the "still missing after init" branch.
type missingAfterInitRPC struct {
	*testutil.FakeRPC
}

func (m *missingAfterInitRPC) GetAccountInfoWithOpts(_ context.Context, _ solana.PublicKey, _ *rpc.GetAccountInfoOpts) (*rpc.GetAccountInfoResult, error) {
	return nil, rpc.ErrNotFound
}

func TestBuildSubscriptionActivationSAStillMissingAfterInitErrors(t *testing.T) {
	signer := testutil.NewPrivateKey()
	md := makeMethodDetails(t, false, "")
	stub := &missingAfterInitRPC{FakeRPC: testutil.NewFakeRPC()}

	_, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, stub, md, SubscriptionActivationOptions{},
	)
	if err == nil {
		t.Fatal("SA still missing after init broadcast must error")
	}
}

func TestFetchAccountDataNotFoundErrors(t *testing.T) {
	stub := testutil.NewFakeRPC()
	_, err := fetchAccountData(context.Background(), stub, testutil.NewPrivateKey().PublicKey())
	if err == nil {
		t.Fatal("unknown account must error")
	}
}

func TestBuildSubscriptionActivationRejectsInvalidFields(t *testing.T) {
	cases := map[string]func(md *paycore.SubscriptionMethodDetails){
		"tokenProgram": func(md *paycore.SubscriptionMethodDetails) { md.TokenProgram = "not-a-pubkey" },
		"planId":       func(md *paycore.SubscriptionMethodDetails) { md.PlanID = "not-a-pubkey" },
		"puller":       func(md *paycore.SubscriptionMethodDetails) { md.Puller = "not-a-pubkey" },
		"merchant":     func(md *paycore.SubscriptionMethodDetails) { md.Merchant = "not-a-pubkey" },
		"recipient":    func(md *paycore.SubscriptionMethodDetails) { md.Recipient = "not-a-pubkey" },
	}
	for name, mutate := range cases {
		signer := testutil.NewPrivateKey()
		rpcClient := testutil.NewFakeRPC()
		md := makeMethodDetails(t, false, "")
		mutate(&md)
		if _, err := BuildSubscriptionActivationTransaction(
			context.Background(), signer, rpcClient, md,
			SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
		); err == nil {
			t.Errorf("invalid %s must error", name)
		}
	}
}

func TestBuildSubscriptionActivationRejectsMissingSubscribeData(t *testing.T) {
	cases := map[string]func(md *paycore.SubscriptionMethodDetails){
		"planBump":            func(md *paycore.SubscriptionMethodDetails) { md.PlanBump = nil },
		"expectedPeriodHours": func(md *paycore.SubscriptionMethodDetails) { md.ExpectedPeriodHours = nil },
		"expectedCreatedAt":   func(md *paycore.SubscriptionMethodDetails) { md.ExpectedCreatedAt = nil },
		"amountEmpty":         func(md *paycore.SubscriptionMethodDetails) { md.Amount = "" },
		"amountInvalid":       func(md *paycore.SubscriptionMethodDetails) { md.Amount = "not-a-number" },
	}
	for name, mutate := range cases {
		signer := testutil.NewPrivateKey()
		rpcClient := testutil.NewFakeRPC()
		md := makeMethodDetails(t, false, "")
		mutate(&md)
		if _, err := BuildSubscriptionActivationTransaction(
			context.Background(), signer, rpcClient, md,
			SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
		); err == nil {
			t.Errorf("missing/invalid %s must error", name)
		}
	}
}

// blockhashFailRPC fails the blockhash fetch and carries no override, forcing
// ResolveRecentBlockhash to error inside the builder.
type blockhashFailRPC struct {
	*testutil.FakeRPC
}

func (b *blockhashFailRPC) GetLatestBlockhash(_ context.Context, _ rpc.CommitmentType) (*rpc.GetLatestBlockhashResult, error) {
	return nil, errors.New("blockhash rpc down")
}

func TestBuildSubscriptionActivationBlockhashFailureErrors(t *testing.T) {
	signer := testutil.NewPrivateKey()
	stub := &blockhashFailRPC{FakeRPC: testutil.NewFakeRPC()}
	md := makeMethodDetails(t, false, "")
	md.RecentBlockhash = "" // force an RPC resolve, which fails

	if _, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, stub, md,
		SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
	); err == nil {
		t.Fatal("blockhash resolve failure must error")
	}
}

func TestBuildSubscriptionActivationFeePayerInvalidKeyErrors(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()
	md := makeMethodDetails(t, true, "not-a-pubkey")

	if _, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, rpcClient, md,
		SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
	); err == nil {
		t.Fatal("feePayer=true with invalid feePayerKey must error")
	}
}

func TestBuildSubscriptionActivationHeaderDecodeFailureErrors(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()

	// methodDetails encoded as a JSON number cannot decode into the struct, so
	// decodeSubscriptionChallenge (and thus the header builder) must error.
	encoded, err := core.NewBase64URLJSONValue(map[string]any{
		"externalId":    "x",
		"methodDetails": 42,
	})
	if err != nil {
		t.Fatal(err)
	}
	challenge := core.NewChallengeWithSecret("secret", "MPP Subscription",
		core.NewMethodName("solana"), core.NewIntentName("subscription"), encoded)

	if _, err := BuildSubscriptionActivationHeader(
		context.Background(), signer, rpcClient, challenge, SubscriptionActivationOptions{},
	); err == nil {
		t.Fatal("undecodable methodDetails must error")
	}
}

func TestBuildSubscriptionActivationInvalidProgramIDErrors(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()
	md := makeMethodDetails(t, false, "")
	md.ProgramID = "not-a-pubkey"

	_, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, rpcClient, md,
		SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(0)},
	)
	if err == nil {
		t.Fatal("invalid programId must error")
	}
}

func TestBuildSubscriptionActivationCustomProgramIDPinned(t *testing.T) {
	signer := testutil.NewPrivateKey()
	rpcClient := testutil.NewFakeRPC()
	md := makeMethodDetails(t, false, "")
	// A syntactically valid but distinct program id flows through the override
	// branch in BuildSubscriptionActivationTransaction.
	md.ProgramID = testutil.NewPrivateKey().PublicKey().String()

	_, err := BuildSubscriptionActivationTransaction(
		context.Background(), signer, rpcClient, md,
		SubscriptionActivationOptions{SubscriptionAuthorityInitID: pinnedInitID(7)},
	)
	if err != nil {
		t.Fatal(err)
	}
}
