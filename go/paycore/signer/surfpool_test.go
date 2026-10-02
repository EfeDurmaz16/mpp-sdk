package signer_test

import (
	"context"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/solana-foundation/pay-kit/go/paycore/signer"
	"github.com/solana-foundation/pay-kit/go/paycore/solanatx"
	"github.com/solana-foundation/pay-kit/go/paykit"
	solana "github.com/solana-foundation/solana-go/v2"
	"github.com/solana-foundation/solana-go/v2/programs/system"
	"github.com/solana-foundation/solana-go/v2/rpc"
)

// This opt-in test executes a transfer on an isolated local validator. It uses
// fresh Memory keys, requests local funds, and verifies both balances and RPC
// rejection of an invalid signature. It never uses a saved wallet.
func TestMemorySignerSurfpool(t *testing.T) {
	endpoint := os.Getenv("PAYKIT_TEST_LOCAL_RPC")
	if endpoint == "" {
		t.Skip("set PAYKIT_TEST_LOCAL_RPC to an isolated Surfpool RPC")
	}
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "http" || u.User != nil || (u.Hostname() != "127.0.0.1" && u.Hostname() != "::1") {
		t.Fatal("PAYKIT_TEST_LOCAL_RPC must be a loopback HTTP endpoint")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client := rpc.New(endpoint)
	payer := signer.Generate()
	payerKey := solana.MustPublicKeyFromBase58(string(payer.Pubkey()))
	recipient := solana.MustPublicKeyFromBase58(string(signer.Generate().Pubkey()))
	const funding, amount = uint64(10_000_000), uint64(2_000_000)
	airdrop, err := client.RequestAirdrop(ctx, payerKey, funding, rpc.CommitmentConfirmed)
	if err != nil {
		t.Fatal(err)
	}
	if err := solanatx.WaitForConfirmation(ctx, client, airdrop); err != nil {
		t.Fatal(err)
	}
	before, err := client.GetBalance(ctx, payerKey, rpc.CommitmentConfirmed)
	if err != nil {
		t.Fatal(err)
	}
	blockhash, err := solanatx.ResolveRecentBlockhash(ctx, client, "")
	if err != nil {
		t.Fatal(err)
	}
	tx, err := solanatx.NewV0Transaction(
		[]solana.Instruction{system.NewTransferInstruction(amount, payerKey, recipient).Build()},
		blockhash, solana.TransactionPayer(payerKey))
	if err != nil {
		t.Fatal(err)
	}
	result, err := paykit.SignTransaction(ctx, tx, payer)
	if err != nil || !result.IsComplete() {
		t.Fatalf("signing complete=%v err=%v", result.IsComplete(), err)
	}
	tx, err = solanatx.DecodeTransactionBase64(result.EncodedTransaction)
	if err != nil {
		t.Fatal(err)
	}
	if err := solanatx.SimulateTransaction(ctx, client, tx); err != nil {
		t.Fatal(err)
	}
	// The local validator must verify the actual Keychain-produced signature.
	tx.Signatures[0][0] ^= 1
	err = solanatx.SimulateTransaction(ctx, client, tx)
	tx.Signatures[0][0] ^= 1
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "signature") {
		t.Fatalf("invalid signature was not rejected: %v", err)
	}
	signature, err := solanatx.SendTransaction(ctx, client, tx)
	if err != nil {
		t.Fatal(err)
	}
	if err := solanatx.WaitForConfirmation(ctx, client, signature); err != nil {
		t.Fatal(err)
	}
	landed, meta, err := solanatx.FetchTransaction(ctx, client, signature)
	if err != nil || meta == nil || meta.Err != nil {
		t.Fatalf("fetch transaction: meta=%+v err=%v", meta, err)
	}
	if landed.Signatures[0] != tx.Signatures[0] {
		t.Fatal("RPC returned a different transaction signature")
	}
	after, err := client.GetBalance(ctx, payerKey, rpc.CommitmentConfirmed)
	if err != nil {
		t.Fatal(err)
	}
	paid, err := client.GetBalance(ctx, recipient, rpc.CommitmentConfirmed)
	if err != nil {
		t.Fatal(err)
	}
	if paid.Value != amount || before.Value-after.Value != amount+meta.Fee {
		t.Fatalf("unexpected settlement balances: recipient=%d debit=%d fee=%d", paid.Value, before.Value-after.Value, meta.Fee)
	}
	t.Logf("confirmed v0 transfer: recipient=%d lamports fee=%d signature=%s", paid.Value, meta.Fee, signature)
}
