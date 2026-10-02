package solanatx

import (
	"encoding/base64"
	"strconv"
	"strings"
	"testing"

	solana "github.com/solana-foundation/solana-go/v2"
	"github.com/solana-foundation/solana-go/v2/programs/system"

	"github.com/solana-foundation/pay-kit/go/internal/testutil"
)

func signedV1Transaction(t *testing.T) *solana.Transaction {
	t.Helper()
	key := testutil.NewPrivateKey()
	tx, err := solana.NewTransaction(
		[]solana.Instruction{system.NewTransferInstruction(1, key.PublicKey(), testutil.NewPrivateKey().PublicKey()).Build()},
		testutil.NewFakeRPC().Blockhash,
		solana.TransactionPayer(key.PublicKey()),
		solana.TransactionV1Config(solana.TransactionConfig{}.WithComputeUnitLimit(20_000).WithPriorityFee(1)),
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := SignTransaction(tx, key); err != nil {
		t.Fatal(err)
	}
	return tx
}

func TestDecodeTransactionAcceptsV1(t *testing.T) {
	tx := signedV1Transaction(t)
	wire, err := tx.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	if wire[0] != 0x81 {
		t.Fatalf("transaction prefix = %#x, want 0x81", wire[0])
	}
	decoded, err := DecodeTransaction(wire)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Message.GetVersion() != solana.MessageVersionV1 || decoded.Signatures[0] != tx.Signatures[0] {
		t.Fatal("decode changed v1 version or signature")
	}
	if *decoded.Message.TransactionConfig.ComputeUnitLimit != 20_000 || *decoded.Message.TransactionConfig.PriorityFee != 1 {
		t.Fatal("decode lost inline budget")
	}
	if err := decoded.VerifySignatures(); err != nil {
		t.Fatalf("decoded signature invalid: %v", err)
	}
	if _, err := DecodeTransactionBase64(base64.StdEncoding.EncodeToString(wire)); err != nil {
		t.Fatal(err)
	}
}

func TestDecodeTransactionRejectsMalformedV1Wire(t *testing.T) {
	wire, err := signedV1Transaction(t).MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name   string
		mutate func([]byte) []byte
		want   string
	}{
		{"trailing data", func(b []byte) []byte { return append(b, 0) }, "trailing bytes"},
		{"truncated signature", func(b []byte) []byte { return b[:len(b)-1] }, "signatures"},
		{"truncated header", func(b []byte) []byte { return b[:4] }, "decode"},
		{"unknown envelope", func(b []byte) []byte { b[0] = 0x82; return b }, "unsupported transaction message version 2"},
		{"unknown config bit", func(b []byte) []byte { b[4] |= 0x80; return b }, "config mask"},
		{"partial priority fee mask", func(b []byte) []byte { b[4] &^= 0x02; return b }, "config mask"},
	} {
		t.Run(test.name, func(t *testing.T) {
			mutated := test.mutate(append([]byte(nil), wire...))
			if _, err := DecodeTransaction(mutated); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("err = %v, want %q", err, test.want)
			}
		})
	}
}

func TestDecodeTransactionSanitizesV1(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func(*solana.Transaction)
		want   string
	}{
		{"readonly payer", func(tx *solana.Transaction) { tx.Message.Header.NumReadonlySignedAccounts = 1 }, "no writable signer"},
		{"duplicate address", func(tx *solana.Transaction) { tx.Message.AccountKeys[1] = tx.Message.AccountKeys[0] }, "duplicate addresses"},
		{"program index", func(tx *solana.Transaction) { tx.Message.Instructions[0].ProgramIDIndex = 99 }, "program_id_index"},
		{"account index", func(tx *solana.Transaction) { tx.Message.Instructions[0].Accounts[0] = 99 }, "account index"},
		{"address count", func(tx *solana.Transaction) {
			for len(tx.Message.AccountKeys) <= solana.MaxAddressesV1 {
				tx.Message.AccountKeys = append(tx.Message.AccountKeys, testutil.NewPrivateKey().PublicKey())
			}
		}, "too many addresses"},
		{"instruction count", func(tx *solana.Transaction) {
			for len(tx.Message.Instructions) <= solana.MaxInstructionsV1 {
				tx.Message.Instructions = append(tx.Message.Instructions, tx.Message.Instructions[0])
			}
		}, "too many instructions"},
		{"signature count", func(tx *solana.Transaction) {
			for len(tx.Message.AccountKeys) <= solana.MaxSignaturesV1 {
				tx.Message.AccountKeys = append(tx.Message.AccountKeys, testutil.NewPrivateKey().PublicKey())
			}
			tx.Message.Header.NumRequiredSignatures = solana.MaxSignaturesV1 + 1
			tx.Signatures = make([]solana.Signature, solana.MaxSignaturesV1+1)
		}, "too many signatures"},
		{"heap alignment", func(tx *solana.Transaction) {
			tx.Message.TransactionConfig = tx.Message.TransactionConfig.WithHeapSize(32_769)
		}, "multiple of 1024"},
		{"heap maximum", func(tx *solana.Transaction) {
			tx.Message.TransactionConfig = tx.Message.TransactionConfig.WithHeapSize(solana.MaxHeapSizeV1 + 1024)
		}, "out of bounds"},
	} {
		t.Run(test.name, func(t *testing.T) {
			tx := signedV1Transaction(t)
			test.mutate(tx)
			wire, err := tx.MarshalBinary()
			if err != nil {
				t.Fatal(err)
			}
			if _, err := solana.TransactionFromBytes(wire); err != nil {
				t.Fatalf("fixture must decode before sanitize: %v", err)
			}
			if _, err := DecodeTransaction(wire); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("err = %v, want %q", err, test.want)
			}
		})
	}
}

func TestDecodeTransactionV1SizeLimit(t *testing.T) {
	tx := signedV1Transaction(t)
	wire, err := tx.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	tx.Message.Instructions[0].Data = make([]byte, len(tx.Message.Instructions[0].Data)+solana.MaxTransactionSizeV1-len(wire))
	wire, err = tx.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	if len(wire) != solana.MaxTransactionSizeV1 {
		t.Fatalf("fixture size=%d", len(wire))
	}
	if _, err := DecodeTransaction(wire); err != nil {
		t.Fatalf("4096-byte transaction rejected: %v", err)
	}
	tx.Message.Instructions[0].Data = append(tx.Message.Instructions[0].Data, 0)
	wire, err = tx.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeTransaction(wire); err == nil || !strings.Contains(err.Error(), "size 4097 exceeds maximum 4096") {
		t.Fatalf("err = %v, want oversized transaction rejection", err)
	}
}

func TestDecodeTransactionTruncatedEnvelope(t *testing.T) {
	wire := signedV0Wire(t)
	for _, length := range []int{0, 1, 32, 64, 65, 66} {
		t.Run(strconv.Itoa(length), func(t *testing.T) {
			if _, err := DecodeTransaction(wire[:length]); err == nil {
				t.Fatalf("accepted truncated envelope of %d bytes", length)
			}
		})
	}
}
