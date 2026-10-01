package signer_test

import (
	"context"
	"crypto/ed25519"
	"testing"

	"github.com/solana-foundation/pay-kit/go/paycore/signer"
	"github.com/solana-foundation/pay-kit/go/paykit"
	"github.com/solana-foundation/solana-go/v2"
	"github.com/solana-foundation/solana-go/v2/programs/system"
)

func TestMemoryTransactionAndVoucherSignatures(t *testing.T) {
	s := signer.Generate()
	transactionSigner, ok := s.(paykit.TransactionSigner)
	if !ok {
		t.Fatal("Memory factory discarded its transaction capability")
	}
	pubkey := solana.MustPublicKeyFromBase58(string(s.Pubkey()))
	tx, err := solana.NewTransaction(
		[]solana.Instruction{system.NewTransferInstruction(1, pubkey, solana.SystemProgramID).Build()},
		solana.Hash{}, solana.TransactionPayer(pubkey))
	if err != nil {
		t.Fatal(err)
	}
	result, err := transactionSigner.SignTransaction(context.Background(), tx)
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsComplete() {
		t.Fatal("single-signer transaction is incomplete")
	}
	message, err := tx.Message.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	if !ed25519.Verify(pubkey[:], message, result.Signature[:]) {
		t.Fatal("transaction signature invalid")
	}
	message[len(message)-1] ^= 1
	if ed25519.Verify(pubkey[:], message, result.Signature[:]) {
		t.Fatal("signature accepted a modified message")
	}
	voucher := []byte("off-chain session voucher")
	signature, err := s.Sign(context.Background(), voucher)
	if err != nil {
		t.Fatal(err)
	}
	if !ed25519.Verify(pubkey[:], voucher, signature) {
		t.Fatal("voucher message signature invalid")
	}
}

func TestFromBytesRejectsInconsistentKeypair(t *testing.T) {
	key := testSecret(t)
	key[63] ^= 1
	if _, err := signer.FromBytes(key); err == nil {
		t.Fatal("accepted inconsistent seed and public key")
	}
}

func TestImportedDemoKeyKeepsMainnetGuard(t *testing.T) {
	if !signer.FromKeychain(testDemoBackend{TransactionSigner: signer.Demo().(paykit.TransactionSigner)}).IsDemo() {
		t.Fatal("importing the demo backend bypassed the mainnet guard")
	}
}

type testDemoBackend struct{ paykit.TransactionSigner }

func (b testDemoBackend) Pubkey() solana.PublicKey {
	return solana.MustPublicKeyFromBase58(string(b.TransactionSigner.Pubkey()))
}
func (b testDemoBackend) SignMessage(ctx context.Context, msg []byte) (solana.Signature, error) {
	raw, err := b.Sign(ctx, msg)
	var signature solana.Signature
	copy(signature[:], raw)
	return signature, err
}
func (b testDemoBackend) IsAvailable(context.Context) bool { return true }
