package main

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"

	solana "github.com/solana-foundation/solana-go/v2"
)

func TestReadPrivateKeyEnvParsesJSONByteArray(t *testing.T) {
	privateKey, err := solana.NewRandomPrivateKey()
	if err != nil {
		t.Fatalf("new private key: %v", err)
	}
	values := make([]int, len(privateKey))
	for i, value := range []byte(privateKey) {
		values[i] = int(value)
	}
	raw, err := json.Marshal(values)
	if err != nil {
		t.Fatalf("marshal private key: %v", err)
	}

	t.Setenv("MPP_HARNESS_CLIENT_SECRET_KEY", " \n"+string(raw)+"\n")

	got, err := readPrivateKeyEnv("MPP_HARNESS_CLIENT_SECRET_KEY")
	if err != nil {
		t.Fatalf("read private key: %v", err)
	}
	if got.PublicKey() != privateKey.PublicKey() {
		t.Fatal("parsed key changed the public key")
	}
	message := []byte("harness key parsing test")
	signature, err := got.Sign(message)
	if err != nil || !signature.Verify(privateKey.PublicKey(), message) {
		t.Fatalf("parsed key could not produce a valid signature: %v", err)
	}
}

func TestReadPrivateKeyEnvRejectsInvalidKeys(t *testing.T) {
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
			t.Setenv("MPP_HARNESS_CLIENT_SECRET_KEY", test.raw)
			got, err := readPrivateKeyEnv("MPP_HARNESS_CLIENT_SECRET_KEY")
			if err == nil || got != nil {
				t.Fatalf("invalid private key must return nil and an error; got key=%t, err=%v", got != nil, err)
			}
		})
	}
}

func TestResponseHeadersLowercaseAndJoinValues(t *testing.T) {
	headers := http.Header{}
	headers.Add("X-Fixture-Settlement", "abc")
	headers.Add("Vary", "Authorization")
	headers.Add("Vary", "Accept")

	got := responseHeaders(headers)
	if got[fixtureSettlementHeader] != "abc" {
		t.Fatalf("expected settlement header, got %#v", got)
	}
	if got["vary"] != "Authorization, Accept" {
		t.Fatalf("expected joined vary header, got %q", got["vary"])
	}
}

func TestParseResponseBodyKeepsJSONObjects(t *testing.T) {
	body := parseResponseBody([]byte(`{"ok":true,"paid":true}`))
	object, ok := body.(map[string]any)
	if !ok {
		t.Fatalf("expected JSON object, got %T", body)
	}
	if object["ok"] != true || object["paid"] != true {
		t.Fatalf("unexpected response body: %#v", object)
	}
}

func TestParseResponseBodyKeepsPlainText(t *testing.T) {
	body := parseResponseBody([]byte("paid"))
	if body != "paid" {
		t.Fatalf("expected plain body, got %#v", body)
	}
}

func TestRunProcessAdapterRequiresRPCURL(t *testing.T) {
	t.Setenv("MPP_HARNESS_TARGET_URL", "http://127.0.0.1/protected")

	if err := runProcessAdapter(io.Discard); err == nil {
		t.Fatal("expected missing RPC URL to fail")
	}
}

// TestResolveProtocolMode pins the adapter dispatch: the harness matrix sets
// both TARGET_URL namespaces on every client run, so the explicit
// PAY_KIT_HARNESS_PROTOCOL hint must win over the namespace probe. Without
// the hint taking precedence, MPP cells run the x402 adapter and every
// positive charge scenario dies on the unanswered MPP challenge.
func TestResolveProtocolMode(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want string
	}{
		{
			name: "hint mpp wins over both target urls",
			env: map[string]string{
				"PAY_KIT_HARNESS_PROTOCOL": "mpp",
				"MPP_HARNESS_TARGET_URL":   "http://127.0.0.1/protected",
				"X402_HARNESS_TARGET_URL":  "http://127.0.0.1/protected",
			},
			want: "mpp",
		},
		{
			name: "hint x402 wins over both target urls",
			env: map[string]string{
				"PAY_KIT_HARNESS_PROTOCOL": "x402",
				"MPP_HARNESS_TARGET_URL":   "http://127.0.0.1/protected",
				"X402_HARNESS_TARGET_URL":  "http://127.0.0.1/protected",
			},
			want: "x402",
		},
		{
			name: "no hint probes x402 namespace first",
			env: map[string]string{
				"X402_HARNESS_TARGET_URL": "http://127.0.0.1/protected",
			},
			want: "x402",
		},
		{
			name: "no hint falls back to mpp namespace",
			env: map[string]string{
				"MPP_HARNESS_TARGET_URL": "http://127.0.0.1/protected",
			},
			want: "mpp",
		},
		{
			name: "no env selects the legacy harness",
			env:  map[string]string{},
			want: "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := resolveProtocolMode(func(key string) string { return tc.env[key] })
			if got != tc.want {
				t.Fatalf("resolveProtocolMode = %q, want %q", got, tc.want)
			}
		})
	}
}
