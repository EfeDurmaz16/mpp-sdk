package paykit

import (
	"context"
	"fmt"

	"github.com/solana-foundation/solana-go/v2"
	keychain "github.com/solana-foundation/solana-keychain/go/core/v2"
)

// Signer is the Ed25519 signer interface every signer backend
// implements. Local signers (signer.Demo, signer.FromFile, ...) ignore
// the context; remote enclave (KMS) signers honor it
// for network I/O timeouts and cancellation.
//
// The interface deliberately never exposes the raw secret key: both the
// x402 facilitator cosign and the MPP fee-payer cosign go through
// Sign, so a KMS- or HSM-backed signer that can never export its key
// still satisfies the contract. This diverges from the original
// DESIGN.md sketch (which had a FeePayer() bool method on Signer);
// fee-payer policy lives on Operator, not the key source.
type Signer interface {
	// Pubkey returns the base58 Solana pubkey.
	Pubkey() Address
	// Sign produces a 64-byte Ed25519 signature over the message bytes.
	Sign(ctx context.Context, message []byte) ([]byte, error)
	// IsDemo reports whether this is the package-shipped demo keypair.
	// paykit.New refuses to boot on solana_mainnet when this returns
	// true.
	IsDemo() bool
}

// TransactionSigner optionally exposes transaction-aware signing. Existing
// message-only Signer implementations remain supported through Keychain's
// sign-and-attach helper. Implementations must preserve the transaction message
// and any signatures already present; modifying and sending backends do not
// satisfy this contract.
type TransactionSigner interface {
	Signer
	SignTransaction(context.Context, *solana.Transaction) (keychain.SignedTransaction, error)
}

// SignTransaction adds the operator's signature without broadcasting. A payment
// can still need other signatures, so a partial result is valid here.
func SignTransaction(ctx context.Context, tx *solana.Transaction, signer Signer) (keychain.SignedTransaction, error) {
	if transactionSigner, ok := signer.(TransactionSigner); ok {
		return transactionSigner.SignTransaction(ctx, tx)
	}
	pubkey, err := solana.PublicKeyFromBase58(string(signer.Pubkey()))
	if err != nil {
		return keychain.SignedTransaction{}, fmt.Errorf("signer pubkey: %w", err)
	}
	return keychain.SignTransactionWith(ctx, tx, pubkey,
		func(ctx context.Context, message []byte) (solana.Signature, error) {
			raw, err := signer.Sign(ctx, message)
			if err != nil {
				return solana.Signature{}, err
			}
			if len(raw) != len(solana.Signature{}) {
				return solana.Signature{}, fmt.Errorf("signer signature length %d, want 64", len(raw))
			}
			var signature solana.Signature
			copy(signature[:], raw)
			return signature, nil
		})
}
