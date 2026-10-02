package server

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"testing"

	"github.com/solana-foundation/pay-kit/go/internal/testutil"
	"github.com/solana-foundation/pay-kit/go/paycore"
	"github.com/solana-foundation/pay-kit/go/paycore/paymentchannels"
	"github.com/solana-foundation/pay-kit/go/paycore/solanatx"
	core "github.com/solana-foundation/pay-kit/go/protocols/mpp/core"
	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
	"github.com/solana-foundation/solana-go/v2"
	keychain "github.com/solana-foundation/solana-keychain/go/core/v2"
	"github.com/solana-foundation/solana-keychain/go/signers/memory/v2"
)

// Count the transaction capability, so rejection proves no sponsor signature
// was requested and acceptance proves Keychain completed the partial signature.
type countedV1Signer struct {
	keychain.TransactionSigner
	calls int
}

func (s *countedV1Signer) SignTransaction(ctx context.Context, tx *solana.Transaction) (keychain.SignedTransaction, error) {
	s.calls++
	return s.TransactionSigner.SignTransaction(ctx, tx)
}

func v1MemorySigner(t *testing.T, key solana.PrivateKey) *memory.Signer {
	t.Helper()
	s, err := memory.New(memory.Config{PrivateKey: key})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func v1Budget() solana.TransactionConfig {
	return solana.TransactionConfig{}.WithComputeUnitLimit(maxComputeUnitLimit).WithPriorityFee(2_000)
}

func TestV1ChargePreBroadcastAndPublicVerification(t *testing.T) {
	for _, tc := range []struct {
		name                      string
		budget                    solana.TransactionConfig
		deception, wrongRecipient bool
	}{
		{name: "valid", budget: v1Budget()},
		{name: "huge_fee", budget: v1Budget().WithPriorityFee(2_001)},
		{name: "max_uint_fee", budget: v1Budget().WithPriorityFee(math.MaxUint64)},
		{name: "missing_cu", budget: solana.TransactionConfig{}.WithPriorityFee(1)},
		{name: "zero_cu", budget: v1Budget().WithComputeUnitLimit(0)},
		{name: "over_limit", budget: v1Budget().WithComputeUnitLimit(maxComputeUnitLimit + 1)},
		{name: "compute_budget_deception", budget: v1Budget(), deception: true},
		{name: "wrong_recipient", budget: v1Budget(), wrongRecipient: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			payer, operator, recipient := testutil.NewPrivateKey(), testutil.NewPrivateKey(), testutil.NewPrivateKey().PublicKey()
			sponsor := &countedV1Signer{TransactionSigner: v1MemorySigner(t, operator)}
			rpcClient := testutil.NewFakeRPC()
			rpcClient.TxVersion = "1"
			handler, err := New(Config{Recipient: recipient.String(), Currency: "sol", Decimals: 9, Network: "localnet", SecretKey: "test-secret-key-0123456789abcdef", RPC: rpcClient, Store: core.NewMemoryStore(), FeePayerSigner: solanatx.FromKeychain(sponsor)})
			if err != nil {
				t.Fatal(err)
			}
			challenge, err := handler.Charge(ctx, "0.001")
			if err != nil {
				t.Fatal(err)
			}
			var request intents.ChargeRequest
			if err := challenge.Request.Decode(&request); err != nil {
				t.Fatal(err)
			}
			var details paycore.MethodDetails
			raw, err := json.Marshal(request.MethodDetails)
			if err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(raw, &details); err != nil {
				t.Fatal(err)
			}
			to := recipient
			if tc.wrongRecipient {
				to = testutil.NewPrivateKey().PublicKey()
			}
			transfer, err := solanatx.BuildSOLTransfer(payer.PublicKey(), to, 1_000_000)
			if err != nil {
				t.Fatal(err)
			}
			ixs := []solana.Instruction{transfer}
			if tc.deception {
				ixs = append(ixs, solana.NewInstruction(computeBudgetProgramID, nil, []byte{2, 1, 0, 0, 0}))
			}
			// Build v0 first so the adversarial CB instruction can be encoded even
			// though the v1 constructor refuses this no-op instruction itself.
			tx, err := solanatx.NewV0Transaction(ixs, rpcClient.Blockhash, solana.TransactionPayer(operator.PublicKey()))
			if err != nil {
				t.Fatal(err)
			}
			tx.Message.SetVersion(solana.MessageVersionV1)
			tx.Message.TransactionConfig = tc.budget
			if _, err := v1MemorySigner(t, payer).SignTransaction(ctx, tx); err != nil {
				t.Fatal(err)
			}
			payerSignature := tx.Signatures[1]
			encoded, err := solanatx.EncodeTransactionBase64(tx)
			if err != nil {
				t.Fatal(err)
			}
			preErr := VerifyChargeTransactionPreBroadcast(encoded, request, details, "localnet")
			credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.CredentialPayload{Type: "transaction", Transaction: encoded})
			if err != nil {
				t.Fatal(err)
			}
			receipt, verifyErr := handler.VerifyCredentialWithExpected(ctx, credential, request)
			if tc.name != "valid" {
				if preErr == nil || verifyErr == nil {
					t.Fatalf("unsafe v1 accepted: pre=%v public=%v", preErr, verifyErr)
				}
				if !tc.wrongRecipient {
					assertPreBroadcastCode(t, preErr, core.ErrCodeComputeBudgetExceeded)
					assertPreBroadcastCode(t, verifyErr, core.ErrCodeComputeBudgetExceeded)
				}
				if sponsor.calls != 0 || len(rpcClient.Simulated) != 0 || len(rpcClient.Sent) != 0 {
					t.Fatal("rejected v1 reached sponsor or RPC")
				}
				return
			}
			if preErr != nil || verifyErr != nil {
				t.Fatalf("valid v1 rejected: pre=%v public=%v", preErr, verifyErr)
			}
			if receipt.Status != core.ReceiptStatusSuccess || sponsor.calls != 1 || len(rpcClient.Sent) != 1 {
				t.Fatal("valid v1 did not complete public submit path")
			}
			sent := rpcClient.Sent[0]
			if sent.Message.GetVersion() != solana.MessageVersionV1 || sent.Signatures[1] != payerSignature {
				t.Fatal("v1 version or payer signature changed")
			}
			if err := sent.VerifySignatures(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestV1ChargeClientPaidUsesGeneralBudgetCap(t *testing.T) {
	payer, recipient := testutil.NewPrivateKey(), testutil.NewPrivateKey().PublicKey()
	_, tx := encodePreBroadcastSOLTransfer(t, payer, recipient, 1000)
	tx.Message.SetVersion(solana.MessageVersionV1)
	tx.Message.TransactionConfig = v1Budget().WithPriorityFee(1_000_000)
	encoded, err := solanatx.EncodeTransactionBase64(tx)
	if err != nil {
		t.Fatal(err)
	}
	request := intents.ChargeRequest{Amount: "1000", Currency: "sol", Recipient: recipient.String()}
	if err := VerifyChargeTransactionPreBroadcast(encoded, request, paycore.MethodDetails{}, "localnet"); err != nil {
		t.Fatalf("general budget cap: %v", err)
	}
	sponsored := true
	err = VerifyChargeTransactionPreBroadcast(encoded, request, paycore.MethodDetails{FeePayer: &sponsored, FeePayerKey: testutil.NewPrivateKey().PublicKey().String()}, "localnet")
	assertPreBroadcastCode(t, err, core.ErrCodeComputeBudgetExceeded)
}

func TestV1OpenVerificationAndSponsoredSubmit(t *testing.T) {
	for _, fee := range []uint64{2_000, 2_001, math.MaxUint64} {
		t.Run(fmt.Sprintf("fee_%d", fee), func(t *testing.T) {
			ctx := context.Background()
			fixture := buildOpenTxFixture(t)
			operator := testutil.NewPrivateKey()
			fixture.expected.Operator = operator.PublicKey().String()
			ix, err := paymentchannels.BuildOpenInstruction(paymentchannels.OpenChannelParams{Payer: fixture.payer.PublicKey(), RentPayer: operator.PublicKey(), Payee: fixture.payee, Mint: fixture.mint, AuthorizedSigner: fixture.authorized, Salt: openFixtureSalt, OpenSlot: openFixtureOpenSlot, Deposit: openFixtureDeposit, GracePeriod: openFixtureGrace, TokenProgram: solana.TokenProgramID})
			if err != nil {
				t.Fatal(err)
			}
			tx, err := solana.NewTransaction([]solana.Instruction{ix}, solana.Hash{}, solana.TransactionPayer(operator.PublicKey()), solana.TransactionV1Config(v1Budget().WithPriorityFee(fee)))
			if err != nil {
				t.Fatal(err)
			}
			if _, err := v1MemorySigner(t, fixture.payer).SignTransaction(ctx, tx); err != nil {
				t.Fatal(err)
			}
			payerSignature := tx.Signatures[1]
			encoded, err := solanatx.EncodeTransactionBase64(tx)
			if err != nil {
				t.Fatal(err)
			}
			fixture.payload.Transaction = &encoded
			fixture.payload.Signature = ""
			sponsor := &countedV1Signer{TransactionSigner: v1MemorySigner(t, operator)}
			rpcClient := testutil.NewFakeRPC()
			_, verifyErr := VerifyOpenTx(ctx, fixture.expected, &fixture.payload, nil)
			result, submitErr := SubmitOpenTx(ctx, fixture.expected, &fixture.payload, solanatx.FromKeychain(sponsor), rpcClient)
			if fee > 2_000 {
				if verifyErr == nil || submitErr == nil {
					t.Fatalf("unsafe open accepted: verify=%v submit=%v", verifyErr, submitErr)
				}
				if sponsor.calls != 0 || len(rpcClient.Sent) != 0 {
					t.Fatal("unsafe open reached sponsor or broadcast")
				}
				return
			}
			if verifyErr != nil || submitErr != nil {
				t.Fatalf("valid open rejected: verify=%v submit=%v", verifyErr, submitErr)
			}
			if result.ChannelID != fixture.channel.String() || sponsor.calls != 1 || len(rpcClient.Sent) != 1 {
				t.Fatal("valid open not submitted")
			}
			if rpcClient.Sent[0].Signatures[1] != payerSignature {
				t.Fatal("open lost payer signature")
			}
			if err := rpcClient.Sent[0].VerifySignatures(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestV1SelfPaidOpenUsesGeneralBudgetCap(t *testing.T) {
	fixture := buildOpenTxFixture(t)
	tx, err := solanatx.DecodeTransactionBase64(*fixture.payload.Transaction)
	if err != nil {
		t.Fatal(err)
	}
	tx.Message.SetVersion(solana.MessageVersionV1)
	tx.Message.TransactionConfig = v1Budget().WithPriorityFee(1_000_000)
	if _, err := v1MemorySigner(t, fixture.payer).SignTransaction(context.Background(), tx); err != nil {
		t.Fatal(err)
	}
	encoded, err := solanatx.EncodeTransactionBase64(tx)
	if err != nil {
		t.Fatal(err)
	}
	fixture.payload.Transaction = &encoded
	fixture.payload.Signature = tx.Signatures[0].String()
	if _, err := VerifyOpenTx(context.Background(), fixture.expected, &fixture.payload, nil); err != nil {
		t.Fatalf("self-paid v1 open within general budget cap: %v", err)
	}
}
