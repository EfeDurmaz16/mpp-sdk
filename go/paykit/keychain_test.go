package paykit_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"strings"
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

// Deliberately exposes only the original message-signing interface.
type messageOnlySigner struct {
	address paykit.Address
	sign    func(context.Context, []byte) ([]byte, error)
}

func (s messageOnlySigner) Pubkey() paykit.Address { return s.address }
func (s messageOnlySigner) IsDemo() bool           { return false }
func (s messageOnlySigner) Sign(ctx context.Context, message []byte) ([]byte, error) {
	return s.sign(ctx, message)
}

func TestKeychainTransactionCapabilityPreservesPartialSignature(t *testing.T) {
	for _, version := range []struct {
		name    string
		version solana.MessageVersion
	}{
		{"legacy", solana.MessageVersionLegacy},
		{"v0", solana.MessageVersionV0},
	} {
		t.Run(version.name, func(t *testing.T) {
			for _, path := range []string{"transaction", "message fallback"} {
				t.Run(path, func(t *testing.T) {
					testKeychainTransactionCapability(t, version.version, path == "message fallback")
				})
			}
		})
	}
}

func testKeychainTransactionCapability(t *testing.T, version solana.MessageVersion, fallback bool) {
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
	partial, err := payer.SignTransaction(context.Background(), tx)
	if err != nil || partial.IsComplete() {
		t.Fatalf("payer signing: complete=%v err=%v", partial.IsComplete(), err)
	}
	payerSignature := tx.Signatures[1]
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var s paykit.Signer = transactionOnlySigner{Signer: signer.FromKeychain(operator), backend: operator, ctx: ctx}
	if fallback {
		s = messageOnlySigner{address: paykit.Address(operator.Pubkey().String()), sign: func(got context.Context, message []byte) ([]byte, error) {
			if got != ctx {
				return nil, errors.New("message signing context lost")
			}
			return signer.FromKeychain(operator).Sign(got, message)
		}}
	}
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
}

func TestKeychainMessageFallbackErrors(t *testing.T) {
	backendErr := errors.New("backend denied signing")
	key := signer.Generate()
	publicKey := solana.MustPublicKeyFromBase58(string(key.Pubkey()))
	for _, tc := range []struct {
		name      string
		address   paykit.Address
		signature []byte
		signErr   error
		want      string
		calls     int
	}{
		{"invalid public key", "not-base58!", nil, nil, "signer pubkey", 0},
		{"backend error", key.Pubkey(), nil, backendErr, "backend denied signing", 1},
		{"canceled signing", key.Pubkey(), nil, context.Canceled, "context canceled", 1},
		{"short signature", key.Pubkey(), make([]byte, 63), nil, "signature length 63", 1},
		{"long signature", key.Pubkey(), make([]byte, 65), nil, "signature length 65", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tx, err := solana.NewTransaction(
				[]solana.Instruction{system.NewTransferInstruction(1, publicKey, solana.NewWallet().PublicKey()).Build()},
				solana.Hash{}, solana.TransactionPayer(publicKey))
			if err != nil {
				t.Fatal(err)
			}
			calls := 0
			s := messageOnlySigner{address: tc.address, sign: func(context.Context, []byte) ([]byte, error) {
				calls++
				return tc.signature, tc.signErr
			}}
			result, err := paykit.SignTransaction(context.Background(), tx, s)
			if err == nil || !strings.Contains(err.Error(), tc.want) || calls != tc.calls || result.EncodedTransaction != "" {
				t.Fatalf("calls=%d err=%v encoded=%t; want calls=%d error=%q and no transaction", calls, err, result.EncodedTransaction != "", tc.calls, tc.want)
			}
			if tc.signErr != nil && !errors.Is(err, tc.signErr) {
				t.Fatalf("backend error identity lost: %v", err)
			}
		})
	}
}
