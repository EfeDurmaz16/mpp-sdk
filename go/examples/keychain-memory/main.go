// This offline example signs v0 and v1 transactions with the Keychain-backed
// factory the Go SDK uses. It does not connect to an RPC or broadcast anything.
// V1 budgets live in TransactionConfig and are checked by server verifiers.
package main

import (
	"context"
	"crypto/ed25519"
	"fmt"
	"os"

	"github.com/solana-foundation/pay-kit/go/paycore/signer"
	"github.com/solana-foundation/pay-kit/go/paykit"
	"github.com/solana-foundation/solana-go/v2"
	"github.com/solana-foundation/solana-go/v2/programs/system"
)

func run(name string, version solana.TransactionOption) error {
	s := signer.Generate()
	pubkey := solana.MustPublicKeyFromBase58(string(s.Pubkey()))
	recipient := solana.MustPublicKeyFromBase58(string(signer.Generate().Pubkey()))
	tx, err := solana.NewTransaction(
		[]solana.Instruction{system.NewTransferInstruction(1, pubkey, recipient).Build()},
		solana.Hash{}, solana.TransactionPayer(pubkey), version)
	if err != nil {
		return err
	}
	result, err := paykit.SignTransaction(context.Background(), tx, s)
	if err != nil {
		return err
	}
	decoded, err := solana.TransactionFromBase64(result.EncodedTransaction)
	if err != nil {
		return err
	}
	if err := decoded.Sanitize(); err != nil {
		return err
	}
	wire, err := decoded.MarshalBinary()
	if err != nil {
		return err
	}
	if decoded.Message.GetVersion() == solana.MessageVersionV1 && len(wire) > solana.MaxTransactionSizeV1 {
		return fmt.Errorf("v1 transaction exceeds %d bytes", solana.MaxTransactionSizeV1)
	}
	message, err := decoded.Message.MarshalBinary()
	if err != nil {
		return err
	}
	if !ed25519.Verify(pubkey[:], message, decoded.Signatures[0][:]) {
		return fmt.Errorf("decoded transaction signature is invalid")
	}
	fmt.Printf("version: %s\nsigner: %s\ncomplete: %t\nverified: true\nwire: %s\n",
		name, pubkey, result.IsComplete(), result.EncodedTransaction)
	return nil
}

func main() {
	config := solana.TransactionConfig{}.
		WithComputeUnitLimit(20_000).
		WithLoadedAccountsDataSizeLimit(64 * 1024).
		WithPriorityFee(1) // Total lamports for v1, not micro-lamports per CU.
	for _, example := range []struct {
		name    string
		version solana.TransactionOption
	}{
		{"v0", solana.TransactionMessageVersion(solana.MessageVersionV0)},
		{"v1", solana.TransactionV1Config(config)},
	} {
		if err := run(example.name, example.version); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
}
