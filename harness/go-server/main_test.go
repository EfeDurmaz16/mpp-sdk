package main

import (
	"encoding/json"
	"testing"

	solana "github.com/solana-foundation/solana-go/v2"
)

func TestPrivateKeyFromJSON(t *testing.T) {
	key, err := solana.NewRandomPrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	array := func(index, value int) string {
		values := make([]int, len(key))
		for i, value := range key {
			values[i] = int(value)
		}
		values[index] = value
		raw, err := json.Marshal(values)
		if err != nil {
			t.Fatal(err)
		}
		return string(raw)
	}
	t.Run("valid key signs", func(t *testing.T) {
		got, err := privateKeyFromJSON(" \n" + array(0, int(key[0])) + "\n")
		if err != nil {
			t.Fatalf("parse private key: %v", err)
		}
		if got.PublicKey() != key.PublicKey() {
			t.Fatal("parsed key changed the public key")
		}
		message := []byte("harness key parsing test")
		signature, err := got.Sign(message)
		if err != nil || !signature.Verify(key.PublicKey(), message) {
			t.Fatalf("parsed key could not produce a valid signature: %v", err)
		}
	})
	// JSON encoding of []byte produces a base64 string, not a keygen array.
	encodedString, err := json.Marshal([]byte(key))
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct{ name, raw string }{
		{"seed public mismatch", array(32, int(key[32]^1))},
		{"negative byte", array(0, int(key[0])-256)},
		{"overflow byte", array(0, int(key[0])+256)},
		{"short key", "[1,2,3]"},
		{"base64 string", string(encodedString)},
		{"object", "{}"},
		{"malformed array", "["},
		{"missing", ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := privateKeyFromJSON(test.raw)
			if err == nil || got != nil {
				t.Fatalf("invalid private key must return nil and an error; got key=%t, err=%v", got != nil, err)
			}
		})
	}
}
