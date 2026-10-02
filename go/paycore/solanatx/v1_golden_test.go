package solanatx

import (
	"bytes"
	"context"
	"encoding/hex"
	"os"
	"strings"
	"testing"

	solana "github.com/solana-foundation/solana-go/v2"
	"github.com/solana-foundation/solana-keychain/go/signers/memory/v2"
)

// The Rust-produced fixture is independent of the Go encoder under test.
// See testdata/v1-rust-full-config.md for its immutable upstream source.
func TestV1RustGoldenWireAndKeychainSignatures(t *testing.T) {
	fixture, err := os.ReadFile("testdata/v1-rust-full-config.hex")
	if err != nil {
		t.Fatal(err)
	}
	wire, err := hex.DecodeString(strings.Join(strings.Fields(string(fixture)), ""))
	if err != nil {
		t.Fatal(err)
	}
	tx, err := DecodeTransaction(wire)
	if err != nil {
		t.Fatal(err)
	}
	if tx.Message.GetVersion() != solana.MessageVersionV1 || len(tx.Signatures) != 2 || len(tx.Message.Instructions) != 3 {
		t.Fatal("decoded Rust transaction changed version, signatures or instructions")
	}
	config := tx.Message.TransactionConfig
	if config.PriorityFee == nil || *config.PriorityFee != 5_000 ||
		config.ComputeUnitLimit == nil || *config.ComputeUnitLimit != 200_000 ||
		config.LoadedAccountsDataSizeLimit == nil || *config.LoadedAccountsDataSizeLimit != 65_536 ||
		config.HeapSize == nil || *config.HeapSize != 65_536 {
		t.Fatal("decoded Rust transaction changed inline config")
	}
	if err := tx.VerifySignatures(); err != nil {
		t.Fatalf("Rust signatures failed verification: %v", err)
	}
	// Re-sign through the production Keychain path using the public fixture
	// seeds. Matching the original wire proves signing preserves Rust's bytes.
	tx.Signatures = make([]solana.Signature, 2)
	for _, seed := range []byte{1, 2} {
		signer, err := memory.New(memory.Config{PrivateKey: bytes.Repeat([]byte{seed}, 32)})
		if err != nil {
			t.Fatal(err)
		}
		if err := SignTransactionContext(context.Background(), tx, FromKeychain(signer)); err != nil {
			t.Fatal(err)
		}
	}
	actual, err := tx.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actual, wire) {
		t.Fatal("Keychain re-signing differs from the Rust golden wire")
	}
}
