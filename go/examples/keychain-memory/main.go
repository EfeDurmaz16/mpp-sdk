// This offline example signs a v0 transaction with the same Keychain-backed
// factory the Go SDK uses. It does not connect to an RPC or broadcast anything.
package main

import (
	"context"
	"crypto/ed25519"
	"fmt"
	"os"

	"github.com/solana-foundation/pay-kit/go/paycore/signer"
	"github.com/solana-foundation/pay-kit/go/paycore/solanatx"
	"github.com/solana-foundation/pay-kit/go/paykit"
	"github.com/solana-foundation/solana-go/v2"
	"github.com/solana-foundation/solana-go/v2/programs/system"
)

func run() error {
	s := signer.Generate()
	pubkey := solana.MustPublicKeyFromBase58(string(s.Pubkey()))
	recipient := solana.MustPublicKeyFromBase58(string(signer.Generate().Pubkey()))
	tx, err := solanatx.NewV0Transaction(
		[]solana.Instruction{system.NewTransferInstruction(1, pubkey, recipient).Build()},
		solana.Hash{}, solana.TransactionPayer(pubkey))
	if err != nil {
		return err
	}
	result, err := paykit.SignTransaction(context.Background(), tx, s)
	if err != nil {
		return err
	}
	decoded, err := solanatx.DecodeTransactionBase64(result.EncodedTransaction)
	if err != nil {
		return err
	}
	message, err := decoded.Message.MarshalBinary()
	if err != nil {
		return err
	}
	if !ed25519.Verify(pubkey[:], message, decoded.Signatures[0][:]) {
		return fmt.Errorf("decoded transaction signature is invalid")
	}
	fmt.Printf("signer: %s\nversion: v0\ncomplete: %t\nverified: true\nwire: %s\n",
		pubkey, result.IsComplete(), result.EncodedTransaction)
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
