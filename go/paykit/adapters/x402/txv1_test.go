package x402

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"testing"

	"github.com/solana-foundation/pay-kit/go/paycore"
	"github.com/solana-foundation/pay-kit/go/paycore/signer"
	"github.com/solana-foundation/pay-kit/go/paycore/solanatx"
	"github.com/solana-foundation/pay-kit/go/paykit"
	proto "github.com/solana-foundation/pay-kit/go/protocols/x402"
	solana "github.com/solana-foundation/solana-go/v2"
	"github.com/solana-foundation/solana-go/v2/programs/token"
	"github.com/solana-foundation/solana-go/v2/rpc"
	keychain "github.com/solana-foundation/solana-keychain/go/core/v2"
)

func TestVerifyExactV1Layout(t *testing.T) {
	const budgetCode = "invalid_exact_svm_payload_transaction_instructions_compute_price_instruction_too_high"
	for _, tc := range []struct {
		name, want string
		mutate     func(*solana.Transaction, *fixture)
	}{
		{name: "transfer_only"},
		{name: "pinned_memo", mutate: func(tx *solana.Transaction, f *fixture) {
			f.req.ExpectedMemo = "invoice-42"
			tx.Message.AccountKeys = append(tx.Message.AccountKeys, solana.MemoProgramID)
			tx.Message.Instructions = append(tx.Message.Instructions, solana.CompiledInstruction{ProgramIDIndex: uint16(len(tx.Message.AccountKeys) - 1), Data: []byte(f.req.ExpectedMemo)})
		}},
		{name: "wrong_amount", want: "invalid_exact_svm_payload_amount_mismatch", mutate: func(_ *solana.Transaction, f *fixture) { f.req.Amount++ }},
		{name: "wrong_recipient", want: "invalid_exact_svm_payload_recipient_mismatch", mutate: func(_ *solana.Transaction, f *fixture) { f.req.PayTo = solana.NewWallet().PublicKey() }},
		{name: "fee_over_cap", want: budgetCode, mutate: func(tx *solana.Transaction, _ *fixture) {
			tx.Message.TransactionConfig = tx.Message.TransactionConfig.WithPriorityFee(1_000_001)
		}},
		{name: "maximum_fee", want: budgetCode, mutate: func(tx *solana.Transaction, _ *fixture) {
			tx.Message.TransactionConfig = tx.Message.TransactionConfig.WithPriorityFee(math.MaxUint64)
		}},
		{name: "compute_budget_deception", want: budgetCode, mutate: func(tx *solana.Transaction, f *fixture) {
			tx.Message.Instructions = append([]solana.CompiledInstruction{f.computeLimit}, tx.Message.Instructions...)
		}},
		{name: "unknown_suffix", want: "invalid_exact_svm_payload_unknown_fourth_instruction", mutate: func(tx *solana.Transaction, f *fixture) {
			tx.Message.Instructions = append(tx.Message.Instructions, f.transfer)
		}},
		{name: "missing_pinned_memo", want: "invalid_exact_svm_payload_memo_count", mutate: func(_ *solana.Transaction, f *fixture) { f.req.ExpectedMemo = "invoice-42" }},
		{name: "too_many_instructions", want: "invalid_exact_svm_payload_transaction_instructions_length", mutate: func(tx *solana.Transaction, f *fixture) {
			tx.Message.Instructions = []solana.CompiledInstruction{f.transfer, f.transfer, f.transfer, f.transfer, f.transfer}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			tx := f.tx()
			tx.Message.SetVersion(solana.MessageVersionV1)
			tx.Message.TransactionConfig = solana.TransactionConfig{}.WithComputeUnitLimit(200_000).WithPriorityFee(1_000_000)
			tx.Message.Instructions = []solana.CompiledInstruction{f.transfer}
			if tc.mutate != nil {
				tc.mutate(tx, &f)
			}
			err := proto.VerifyExactTransaction(tx, f.req)
			if tc.want == "" {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			var verifyErr *proto.VerifyError
			if !errorsAs(err, &verifyErr) || verifyErr.Code != tc.want {
				t.Fatalf("want %s, got %v", tc.want, err)
			}
		})
	}
}

type countedV1Operator struct {
	paykit.Signer
	calls int
}

func (s *countedV1Operator) SignTransaction(ctx context.Context, tx *solana.Transaction) (keychain.SignedTransaction, error) {
	s.calls++
	return paykit.SignTransaction(ctx, tx, s.Signer)
}

type capturingV1RPC struct {
	*fakeRPC
	wire string
}

func (r *capturingV1RPC) SendEncodedTransactionWithOpts(ctx context.Context, wire string, opts rpc.TransactionOpts) (solana.Signature, error) {
	r.wire = wire
	if opts.SkipPreflight {
		return solana.Signature{}, fmt.Errorf("preflight was disabled")
	}
	return r.fakeRPC.SendEncodedTransactionWithOpts(ctx, wire, opts)
}

func TestVerifyAndSettleV1CosignsAfterFeeGuard(t *testing.T) {
	for _, tc := range []struct {
		name   string
		units  uint32
		fee    uint64
		reject bool
	}{
		{"price boundary", 200_000, 1_000_000, false},
		{"price excess", 200_000, 1_000_001, true},
		{"maximum fee", 200_000, math.MaxUint64, true},
		{"runtime boundary", 1_400_000, 7_000_000, false},
		{"runtime fee excess", 1_400_000, 7_000_001, true},
		{"clamped units boundary", 1_400_001, 7_000_000, false},
		{"clamped units fee excess", 1_400_001, 7_000_001, true},
		{"maximum units boundary", math.MaxUint32, 7_000_000, false},
		{"maximum units fee excess", math.MaxUint32, 7_000_001, true},
		{"inflated declared fee", math.MaxUint32, 21_474_836_475, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			op := &countedV1Operator{Signer: signer.Generate()}
			payer := signer.Generate()
			opKey := solana.MustPublicKeyFromBase58(string(op.Pubkey()))
			payerKey := solana.MustPublicKeyFromBase58(string(payer.Pubkey()))
			mint := solana.MustPublicKeyFromBase58(paycore.USDCMainnetMint)
			destination, err := solanatx.FindAssociatedTokenAddressWithProgram(opKey, mint, solana.TokenProgramID)
			if err != nil {
				t.Fatal(err)
			}
			source, err := solanatx.FindAssociatedTokenAddressWithProgram(payerKey, mint, solana.TokenProgramID)
			if err != nil {
				t.Fatal(err)
			}
			transfer := token.NewTransferCheckedInstruction(1_000, 6, source, mint, destination, payerKey, nil).Build()
			config := solana.TransactionConfig{}.WithComputeUnitLimit(tc.units).
				WithLoadedAccountsDataSizeLimit(64 * 1024 * 1024).WithPriorityFee(tc.fee)
			tx, err := solana.NewTransaction([]solana.Instruction{transfer}, solana.Hash{}, solana.TransactionPayer(opKey), solana.TransactionV1Config(config))
			if err != nil {
				t.Fatal(err)
			}
			partial, err := paykit.SignTransaction(context.Background(), tx, payer)
			if err != nil || partial.IsComplete() {
				t.Fatalf("payer partial signature: complete=%v err=%v", partial.IsComplete(), err)
			}
			before, err := solanatx.DecodeTransactionBase64(partial.EncodedTransaction)
			if err != nil {
				t.Fatal(err)
			}
			beforeMessage, err := before.Message.MarshalBinary()
			if err != nil {
				t.Fatal(err)
			}
			remote := &capturingV1RPC{fakeRPC: &fakeRPC{sig: solana.MustSignatureFromBase58(sampleSig), confirm: rpc.ConfirmationStatusConfirmed}}
			a := &Adapter{cfg: paykit.Config{Network: paykit.SolanaLocalnet, Stablecoins: []paykit.Stablecoin{paykit.USDC}, Operator: paykit.Operator{Signer: op, Recipient: op.Pubkey()}, X402: paykit.X402Config{Scheme: "exact"}}, signer: op, rpc: remote}
			credential, err := json.Marshal(proto.Credential{X402Version: proto.X402Version, Payload: proto.CredentialPayload{Transaction: partial.EncodedTransaction}})
			if err != nil {
				t.Fatal(err)
			}
			payment, err := a.VerifyAndSettle(&paykit.AdapterRequest{Gate: &paykit.Gate{Amount: paykit.MustParseUSD("0.001")}, PaymentSig: base64.StdEncoding.EncodeToString(credential)})
			if tc.reject {
				var paymentErr *paykit.PaymentError
				if !errorsAs(err, &paymentErr) || paymentErr.Code != "invalid_exact_svm_payload_transaction_instructions_compute_price_instruction_too_high" || op.calls != 0 || remote.sends != 0 {
					t.Fatalf("rejected before signing/send: calls=%d sends=%d err=%v", op.calls, remote.sends, err)
				}
				return
			}
			if err != nil || payment == nil || op.calls != 1 || remote.sends != 1 {
				t.Fatalf("settlement: calls=%d sends=%d err=%v", op.calls, remote.sends, err)
			}
			landed, err := solanatx.DecodeTransactionBase64(remote.wire)
			if err != nil {
				t.Fatal(err)
			}
			if err := landed.VerifySignatures(); err != nil {
				t.Fatal(err)
			}
			afterMessage, err := landed.Message.MarshalBinary()
			if err != nil {
				t.Fatal(err)
			}
			if string(beforeMessage) != string(afterMessage) || landed.Signatures[1] != before.Signatures[1] {
				t.Fatal("operator changed the payer's signed message or signature")
			}
		})
	}
}
