package server

import (
	"context"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/solana-foundation/pay-kit/go/internal/testutil"
	"github.com/solana-foundation/pay-kit/go/paycore"
	"github.com/solana-foundation/pay-kit/go/paycore/solanatx"
	core "github.com/solana-foundation/pay-kit/go/protocols/mpp/core"
	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
	"github.com/solana-foundation/solana-go/v2"
	"github.com/solana-foundation/solana-go/v2/rpc"
)

func TestV1SponsoredChargeSurfpool(t *testing.T) {
	endpoint := os.Getenv("PAYKIT_TEST_LOCAL_RPC")
	if endpoint == "" {
		t.Skip("set PAYKIT_TEST_LOCAL_RPC to opt into local Surfpool verification")
	}
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "http" || (u.Hostname() != "127.0.0.1" && u.Hostname() != "::1") || u.User != nil {
		t.Fatal("PAYKIT_TEST_LOCAL_RPC must be a loopback HTTP endpoint")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rpcClient := rpc.New(endpoint)
	payer, operator := testutil.NewPrivateKey(), testutil.NewPrivateKey()
	recipient := testutil.NewPrivateKey().PublicKey()
	for _, key := range []solana.PublicKey{payer.PublicKey(), operator.PublicKey()} {
		signature, err := rpcClient.RequestAirdrop(ctx, key, 1_000_000_000, rpc.CommitmentConfirmed)
		if err != nil {
			t.Fatal(err)
		}
		if err := solanatx.WaitForConfirmation(ctx, rpcClient, signature); err != nil {
			t.Fatal(err)
		}
	}
	balance := func(key solana.PublicKey) uint64 {
		t.Helper()
		result, err := rpcClient.GetBalance(ctx, key, rpc.CommitmentConfirmed)
		if err != nil {
			t.Fatal(err)
		}
		return result.Value
	}
	payerBefore, operatorBefore, recipientBefore := balance(payer.PublicKey()), balance(operator.PublicKey()), balance(recipient)
	handler, err := New(Config{
		Recipient: recipient.String(), Currency: "sol", Decimals: 9, Network: "localnet",
		SecretKey: "test-secret-key-0123456789abcdef", RPC: rpcClient, Store: core.NewMemoryStore(),
		FeePayerSigner: solanatx.FromKeychain(v1MemorySigner(t, operator)),
	})
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
	latest, err := rpcClient.GetLatestBlockhash(ctx, rpc.CommitmentConfirmed)
	if err != nil {
		t.Fatal(err)
	}
	ix, err := solanatx.BuildSOLTransfer(payer.PublicKey(), recipient, 1_000_000)
	if err != nil {
		t.Fatal(err)
	}
	budget := v1Budget().WithLoadedAccountsDataSizeLimit(64 * 1024 * 1024).WithPriorityFee(0)
	tx, err := solana.NewTransaction([]solana.Instruction{ix}, latest.Value.Blockhash,
		solana.TransactionPayer(operator.PublicKey()), solana.TransactionV1Config(budget))
	if err != nil {
		t.Fatal(err)
	}
	partial, err := v1MemorySigner(t, payer).SignTransaction(ctx, tx)
	if err != nil || partial.IsComplete() {
		t.Fatalf("payer partial signing: complete=%v err=%v", partial.IsComplete(), err)
	}
	payerSignature := tx.Signatures[1]
	credential, err := core.NewPaymentCredential(challenge.ToEcho(), paycore.CredentialPayload{Type: "transaction", Transaction: partial.EncodedTransaction})
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := handler.VerifyCredentialWithExpected(ctx, credential, request)
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Status != core.ReceiptStatusSuccess {
		t.Fatalf("receipt status: %s", receipt.Status)
	}
	signature, err := solana.SignatureFromBase58(receipt.Reference)
	if err != nil {
		t.Fatal(err)
	}
	landed, meta, err := solanatx.FetchTransaction(ctx, rpcClient, signature)
	if err != nil {
		t.Fatal(err)
	}
	if landed.Message.GetVersion() != solana.MessageVersionV1 || landed.Signatures[1] != payerSignature {
		t.Fatal("confirmed transaction lost v1 or the original payer signature")
	}
	if err := landed.VerifySignatures(); err != nil {
		t.Fatal(err)
	}
	if meta == nil || meta.Err != nil || meta.Fee == 0 {
		t.Fatalf("invalid confirmed metadata: %+v", meta)
	}
	if payerBefore-balance(payer.PublicKey()) != 1_000_000 || balance(recipient)-recipientBefore != 1_000_000 || operatorBefore-balance(operator.PublicKey()) != meta.Fee {
		t.Fatal("confirmed balances did not charge the payer amount and operator fee")
	}
	t.Logf("public MPP v1 receipt confirmed; amount=1000000 operator_fee=%d signatures=%d", meta.Fee, len(landed.Signatures))
}
