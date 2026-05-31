// Session intent adapter branch for the Go harness client.
//
// Opt-in: activates only when MPP_SESSION_INTEROP_TARGET_URL is set (the
// harness does not ship session scenarios today; see contracts.ts intent
// "session"). It drives the off-chain session lifecycle against a session
// server adapter: fetch the challenge, open a push channel, sign and submit
// a metered commit voucher, then close. Vouchers are produced by the Go SDK
// ActiveSession so the signing-byte layout under unit test is exercised over
// the wire. On-chain open/settlement signatures are stubbed; Surfpool-backed
// runs cover the chain side.
package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"

	solana "github.com/gagliardetto/solana-go"

	mppclient "github.com/solana-foundation/pay-kit/go/protocols/mpp/client"
	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
)

// httpCommitTransport posts commit payloads to the session server's
// /session/commit endpoint and decodes the receipt.
type httpCommitTransport struct {
	baseURL string
	client  *http.Client
}

func (t *httpCommitTransport) Commit(ctx context.Context, _ intents.MeteringDirective, payload intents.CommitPayload) (intents.CommitReceipt, error) {
	var receipt intents.CommitReceipt
	if err := postJSON(ctx, t.client, t.baseURL+"/session/commit", payload, &receipt); err != nil {
		return intents.CommitReceipt{}, err
	}
	return receipt, nil
}

func runSessionAdapter(stdout io.Writer) error {
	baseURL := os.Getenv("MPP_SESSION_INTEROP_TARGET_URL")
	ctx := context.Background()
	httpClient := &http.Client{}

	// 1. Fetch the session challenge.
	var challenge intents.SessionRequest
	if err := getJSON(ctx, httpClient, baseURL+"/session/challenge", &challenge); err != nil {
		return fmt.Errorf("fetch challenge: %w", err)
	}

	// 2. Generate an ephemeral session signer and a channel id.
	signer, err := readSessionSigner()
	if err != nil {
		return err
	}
	channel := solana.NewWallet().PublicKey()
	session := mppclient.NewActiveSession(channel, signer)

	deposit := uint64(1_000_000)
	openTxSig := os.Getenv("MPP_SESSION_INTEROP_OPEN_SIGNATURE")
	if openTxSig == "" {
		openTxSig = solana.NewWallet().PublicKey().String()
	}
	openAction := session.OpenAction(deposit, openTxSig)
	var openResult map[string]any
	if err := postJSON(ctx, httpClient, baseURL+"/session/open", openAction.Open, &openResult); err != nil {
		return fmt.Errorf("open: %w", err)
	}

	// 3. Reserve a metered delivery, sign + commit a voucher for it.
	beginBody := map[string]any{"sessionId": session.ChannelIDStr(), "amount": 125}
	var directive intents.MeteringDirective
	if err := postJSON(ctx, httpClient, baseURL+"/session/begin-delivery", beginBody, &directive); err != nil {
		return fmt.Errorf("begin delivery: %w", err)
	}
	transport := &httpCommitTransport{baseURL: baseURL, client: httpClient}
	consumer := mppclient.NewSessionConsumer(session, transport)
	delivery, err := consumer.Accept(directive)
	if err != nil {
		return fmt.Errorf("accept directive: %w", err)
	}
	receipt, err := delivery.Commit(ctx)
	if err != nil {
		return fmt.Errorf("commit: %w", err)
	}

	// 4. Close the session.
	closeAction, err := session.CloseAction(nil)
	if err != nil {
		return fmt.Errorf("build close: %w", err)
	}
	var closeResult map[string]any
	if err := postJSON(ctx, httpClient, baseURL+"/session/close", closeAction.Close, &closeResult); err != nil {
		return fmt.Errorf("close: %w", err)
	}

	return json.NewEncoder(stdout).Encode(adapterResult{
		Type:           "result",
		Implementation: "go",
		Role:           "client",
		OK:             receipt.Status == intents.CommitStatusCommitted,
		Status:         200,
		ResponseBody: map[string]any{
			"channelId":  session.ChannelIDStr(),
			"committed":  receipt.Cumulative,
			"closeState": closeResult,
		},
	})
}

func readSessionSigner() (solana.PrivateKey, error) {
	if raw := os.Getenv("MPP_SESSION_INTEROP_CLIENT_SECRET_KEY"); raw != "" {
		return readPrivateKeyEnv("MPP_SESSION_INTEROP_CLIENT_SECRET_KEY")
	}
	// Deterministic ephemeral key when none is supplied.
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = 42
	}
	return solana.PrivateKey(ed25519.NewKeyFromSeed(seed)), nil
}

func getJSON(ctx context.Context, client *http.Client, url string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return decodeOrError(resp, out)
}

func postJSON(ctx context.Context, client *http.Client, url string, body, out any) error {
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return decodeOrError(resp, out)
}

func decodeOrError(resp *http.Response, out any) error {
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("status %d: %s", resp.StatusCode, string(raw))
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(raw, out)
}
