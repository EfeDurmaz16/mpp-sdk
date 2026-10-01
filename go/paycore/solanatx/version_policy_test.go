package solanatx

import (
	"strconv"
	"strings"
	"testing"

	solana "github.com/solana-foundation/solana-go/v2"
)

func TestDecodeTransactionRejectsSDKV1Envelope(t *testing.T) {
	tx, err := DecodeTransaction(signedV0Wire(t))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Message.SetVersion(solana.MessageVersionV1); err != nil {
		t.Fatal(err)
	}
	wire, err := tx.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	// Establish that this is a valid v1 envelope understood by the new SDK.
	if _, err := solana.TransactionFromBytes(wire); err != nil {
		t.Fatalf("SDK cannot decode v1 fixture: %v", err)
	}
	if _, err := DecodeTransaction(wire); err == nil || !strings.Contains(err.Error(), "unsupported transaction message version 1") {
		t.Fatalf("err = %v, want pay-kit v1 policy rejection", err)
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
