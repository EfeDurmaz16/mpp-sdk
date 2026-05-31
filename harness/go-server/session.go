// Session intent adapter branch for the Go harness server.
//
// The cross-language harness does not ship session scenarios today, so
// this branch is opt-in: it activates only when the orchestrator sets
// MPP_SESSION_INTEROP_PROTOCOL=session (see harness/src/contracts.ts,
// intent "session"). It exposes the lifecycle endpoints a session client
// drives (open, voucher, commit, close) over HTTP using the Go SDK's
// SessionServer so the same byte-level voucher and channel-store logic
// under unit test is exercised end to end. On-chain settlement is left to
// Surfpool-backed integration runs; this adapter validates the off-chain
// voucher and metering flow.
package main

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
	mppserver "github.com/solana-foundation/pay-kit/go/protocols/mpp/server"
)

func mountSession(mux *http.ServeMux) {
	payTo := requireEnv("MPP_SESSION_INTEROP_PAY_TO")
	operator := optionalEnv("MPP_SESSION_INTEROP_OPERATOR", payTo)
	currency := optionalEnv("MPP_SESSION_INTEROP_CURRENCY", "USDC")
	network := optionalEnv("MPP_SESSION_INTEROP_NETWORK", "localnet")
	capStr := optionalEnv("MPP_SESSION_INTEROP_CAP", "10000000")
	cap, err := strconv.ParseUint(capStr, 10, 64)
	if err != nil {
		cap = 10_000_000
	}

	srv := mppserver.NewSessionServer(mppserver.SessionConfig{
		Operator:  operator,
		Recipient: payTo,
		MaxCap:    cap,
		Currency:  currency,
		Decimals:  6,
		Network:   network,
	}, nil)

	mux.HandleFunc("/session/challenge", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, srv.BuildChallengeRequest(cap))
	})

	mux.HandleFunc("/session/open", func(w http.ResponseWriter, r *http.Request) {
		var payload intents.OpenPayload
		if !decodeJSON(w, r, &payload) {
			return
		}
		state, err := srv.ProcessOpen(r.Context(), payload)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"channelId": state.ChannelID,
			"deposit":   strconv.FormatUint(state.Deposit, 10),
		})
	})

	mux.HandleFunc("/session/voucher", func(w http.ResponseWriter, r *http.Request) {
		var payload intents.VoucherPayload
		if !decodeJSON(w, r, &payload) {
			return
		}
		cumulative, err := srv.VerifyVoucher(r.Context(), payload)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"cumulative": strconv.FormatUint(cumulative, 10)})
	})

	mux.HandleFunc("/session/begin-delivery", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			SessionID string `json:"sessionId"`
			Amount    uint64 `json:"amount"`
		}
		if !decodeJSON(w, r, &body) {
			return
		}
		directive, err := srv.BeginDelivery(r.Context(), mppserver.DeliveryRequest{SessionID: body.SessionID, Amount: body.Amount})
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, directive)
	})

	mux.HandleFunc("/session/commit", func(w http.ResponseWriter, r *http.Request) {
		var payload intents.CommitPayload
		if !decodeJSON(w, r, &payload) {
			return
		}
		receipt, err := srv.ProcessCommit(r.Context(), payload)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, receipt)
	})

	mux.HandleFunc("/session/close", func(w http.ResponseWriter, r *http.Request) {
		var payload intents.ClosePayload
		if !decodeJSON(w, r, &payload) {
			return
		}
		params, err := srv.ProcessClose(r.Context(), payload)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"channelId": params.ChannelID.String(),
			"settled":   strconv.FormatUint(params.Settled, 10),
		})
	})
}

func decodeJSON(w http.ResponseWriter, r *http.Request, out any) bool {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return false
	}
	if err := json.NewDecoder(r.Body).Decode(out); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
