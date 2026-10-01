package paykit_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"

	"github.com/solana-foundation/pay-kit/go/paycore/signer"
	"github.com/solana-foundation/pay-kit/go/paykit"
	"github.com/solana-foundation/solana-go/v2"
	"github.com/solana-foundation/solana-go/v2/programs/system"
	keychain "github.com/solana-foundation/solana-keychain/go/core/v2"
	"github.com/solana-foundation/solana-keychain/go/signers/memory/v2"
)

// A provider can support transaction signing while rejecting raw message
// signing on the payment path. The adapter must preserve that capability.
type transactionOnlySigner struct {
	paykit.Signer
	backend keychain.TransactionSigner
	ctx     context.Context
}

func (s transactionOnlySigner) Sign(context.Context, []byte) ([]byte, error) {
	return nil, errors.New("transaction path used raw message signing")
}

func (s transactionOnlySigner) SignTransaction(ctx context.Context, tx *solana.Transaction) (keychain.SignedTransaction, error) {
	if ctx != s.ctx {
		return keychain.SignedTransaction{}, errors.New("transaction context lost")
	}
	return s.backend.SignTransaction(ctx, tx)
}

func TestKeychainTransactionCapabilityPreservesPartialSignature(t *testing.T) {
	for _, version := range []struct {
		name    string
		version solana.MessageVersion
	}{
		{"legacy", solana.MessageVersionLegacy},
		{"v0", solana.MessageVersionV0},
		{"v1", solana.MessageVersionV1},
	} {
		t.Run(version.name, func(t *testing.T) {
			testKeychainTransactionCapability(t, version.version)
		})
	}
}

func testKeychainTransactionCapability(t *testing.T, version solana.MessageVersion) {
	t.Helper()
	payer, err := memory.New(memory.Config{PrivateKey: make([]byte, 32)})
	if err != nil {
		t.Fatal(err)
	}
	seed := make([]byte, 32)
	seed[0] = 1
	operator, err := memory.New(memory.Config{PrivateKey: seed})
	if err != nil {
		t.Fatal(err)
	}
	tx, err := solana.NewTransaction(
		[]solana.Instruction{system.NewTransferInstruction(1, payer.Pubkey(), operator.Pubkey()).Build()},
		solana.Hash{}, solana.TransactionPayer(operator.Pubkey()),
		solana.TransactionMessageVersion(version))
	if err != nil {
		t.Fatal(err)
	}
	if version == solana.MessageVersionV1 {
		tx.Message.TransactionConfig = solana.TransactionConfig{}.
			WithComputeUnitLimit(20_000).
			WithLoadedAccountsDataSizeLimit(64 * 1024).
			WithPriorityFee(1)
	}
	partial, err := payer.SignTransaction(context.Background(), tx)
	if err != nil || partial.IsComplete() {
		t.Fatalf("payer signing: complete=%v err=%v", partial.IsComplete(), err)
	}
	payerSignature := tx.Signatures[1]
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s := transactionOnlySigner{Signer: signer.FromKeychain(operator), backend: operator, ctx: ctx}
	result, err := paykit.SignTransaction(ctx, tx, s)
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsComplete() || tx.Signatures[1] != payerSignature {
		t.Fatal("operator signing lost the payer signature")
	}
	message, err := tx.Message.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	for i, key := range tx.Message.Signers() {
		if !ed25519.Verify(key[:], message, tx.Signatures[i][:]) {
			t.Fatalf("signature %d does not cover the original message", i)
		}
	}
	decoded, err := solana.TransactionFromBase64(result.EncodedTransaction)
	if err != nil {
		t.Fatal(err)
	}
	if err := decoded.Sanitize(); err != nil {
		t.Fatal(err)
	}
	if decoded.Message.GetVersion() != version {
		t.Fatalf("decoded version = %v, want %v", decoded.Message.GetVersion(), version)
	}
	decodedMessage, err := decoded.Message.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	for i, key := range decoded.Message.Signers() {
		if !ed25519.Verify(key[:], decodedMessage, decoded.Signatures[i][:]) {
			t.Fatalf("decoded signature %d is invalid", i)
		}
	}
	if decoded.Signatures[1] != payerSignature {
		t.Fatal("serialized transaction lost the payer signature")
	}
	if version == solana.MessageVersionV1 {
		decoded.Message.TransactionConfig = decoded.Message.TransactionConfig.WithPriorityFee(2)
		tampered, err := decoded.Message.MarshalBinary()
		if err != nil {
			t.Fatal(err)
		}
		payerKey := payer.Pubkey()
		if ed25519.Verify(payerKey[:], tampered, payerSignature[:]) {
			t.Fatal("payer signature accepted a changed v1 priority fee")
		}
	}
}
