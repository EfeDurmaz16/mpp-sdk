package server

import (
	"context"
	"crypto/ed25519"
	"fmt"
	"strconv"
	"time"

	solana "github.com/gagliardetto/solana-go"

	"github.com/solana-foundation/pay-kit/go/paycore"
	core "github.com/solana-foundation/pay-kit/go/protocols/mpp/core"
	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
	"github.com/solana-foundation/pay-kit/go/protocols/mpp/program"
)

// SessionSplit is a payment split committed at channel open; distributed at close.
type SessionSplit struct {
	Recipient solana.PublicKey
	Bps       uint16
}

// SessionConfig is the server configuration for the session intent.
type SessionConfig struct {
	// Operator is the operator public key (base58), shown to clients.
	Operator string
	// Recipient is the primary payment recipient (base58).
	Recipient string
	// Splits are routed to specific recipients at close.
	Splits []SessionSplit
	// MaxCap is the maximum cap offered per session (base units).
	MaxCap uint64
	// Currency is the asset identifier (e.g. "USDC" or a mint address).
	Currency string
	// Decimals is the token decimals (default 6 for USDC).
	Decimals uint8
	// Network is "mainnet-beta", "devnet", or "localnet".
	Network string
	// ProgramID overrides the payment-channels program (empty = canonical).
	ProgramID string
	// MinVoucherDelta is the minimum voucher increment (0 = no minimum).
	MinVoucherDelta uint64
	// Modes are the session modes this server accepts (empty = push only).
	Modes []intents.SessionMode
	// PullVoucherStrategy is required when Modes includes pull.
	PullVoucherStrategy *intents.SessionPullVoucherStrategy
}

// SessionServer is the server-side session manager. It tracks lifecycle state
// in a ChannelStore and verifies cumulative vouchers. Mirrors SessionServer in
// the Rust spine (server/session.rs).
type SessionServer struct {
	config SessionConfig
	store  core.ChannelStore
}

// NewSessionServer creates a SessionServer. When store is nil an in-memory
// store is used. Defaults mirror the Rust SessionConfig::default.
func NewSessionServer(config SessionConfig, store core.ChannelStore) *SessionServer {
	if config.MaxCap == 0 {
		config.MaxCap = 10_000_000
	}
	if config.Currency == "" {
		config.Currency = "USDC"
	}
	if config.Decimals == 0 {
		config.Decimals = 6
	}
	if config.Network == "" {
		config.Network = "mainnet-beta"
	}
	if len(config.Modes) == 0 {
		config.Modes = []intents.SessionMode{intents.SessionModePush}
	}
	if store == nil {
		store = core.NewMemoryChannelStore()
	}
	return &SessionServer{config: config, store: store}
}

// Store returns the underlying channel store.
func (s *SessionServer) Store() core.ChannelStore { return s.store }

// BuildChallengeRequest builds the SessionRequest to embed in a 402 challenge.
// cap is clamped to MaxCap.
func (s *SessionServer) BuildChallengeRequest(cap uint64) intents.SessionRequest {
	if cap > s.config.MaxCap {
		cap = s.config.MaxCap
	}
	decimals := s.config.Decimals
	req := intents.SessionRequest{
		Cap:       strconv.FormatUint(cap, 10),
		Currency:  s.config.Currency,
		Decimals:  &decimals,
		Network:   s.config.Network,
		Operator:  s.config.Operator,
		Recipient: s.config.Recipient,
	}
	for _, split := range s.config.Splits {
		req.Splits = append(req.Splits, intents.SessionSplit{
			Recipient: split.Recipient.String(),
			Bps:       split.Bps,
		})
	}
	if s.config.ProgramID != "" {
		req.ProgramID = s.config.ProgramID
	}
	if s.config.MinVoucherDelta > 0 {
		req.MinVoucherDelta = strconv.FormatUint(s.config.MinVoucherDelta, 10)
	}
	// Omit modes if only push (clients assume push when modes is absent).
	if !(len(s.config.Modes) == 1 && s.config.Modes[0] == intents.SessionModePush) {
		req.Modes = append([]intents.SessionMode(nil), s.config.Modes...)
	}
	if s.supportsMode(intents.SessionModePull) {
		req.PullVoucherStrategy = s.config.PullVoucherStrategy
	}
	return req
}

func (s *SessionServer) supportsMode(mode intents.SessionMode) bool {
	if len(s.config.Modes) == 0 {
		return mode == intents.SessionModePush
	}
	for _, m := range s.config.Modes {
		if m == mode {
			return true
		}
	}
	return false
}

// ProcessOpen validates the open payload and persists channel state.
func (s *SessionServer) ProcessOpen(ctx context.Context, payload intents.OpenPayload) (core.ChannelState, error) {
	if !s.supportsMode(payload.Mode) {
		return core.ChannelState{}, fmt.Errorf("session mode %q is not supported by this challenge", payload.Mode)
	}
	sessionID, err := payload.SessionID()
	if err != nil {
		return core.ChannelState{}, err
	}
	deposit, err := payload.DepositAmount()
	if err != nil {
		return core.ChannelState{}, err
	}
	if deposit == 0 {
		return core.ChannelState{}, fmt.Errorf("deposit must be greater than zero")
	}
	if deposit > s.config.MaxCap {
		return core.ChannelState{}, fmt.Errorf("deposit %d exceeds max cap %d", deposit, s.config.MaxCap)
	}
	operator := payload.Owner
	if operator == "" {
		operator = payload.Payer
	}
	state := core.ChannelState{
		ChannelID:        sessionID,
		AuthorizedSigner: payload.AuthorizedSigner,
		Deposit:          deposit,
		Operator:         operator,
	}
	if err := s.store.PutChannel(ctx, sessionID, state); err != nil {
		return core.ChannelState{}, err
	}
	return state, nil
}

// PaymentChannelOpenParams validates the push payment-channel open fields
// against the challenge and returns the exact on-chain open params.
func (s *SessionServer) PaymentChannelOpenParams(payload intents.OpenPayload) (program.OpenChannelParams, error) {
	payer, err := parsePayloadPubkey(payload.Payer, "payer")
	if err != nil {
		return program.OpenChannelParams{}, err
	}
	payee, err := parsePayloadPubkey(payload.Payee, "payee")
	if err != nil {
		return program.OpenChannelParams{}, err
	}
	mint, err := parsePayloadPubkey(payload.Mint, "mint")
	if err != nil {
		return program.OpenChannelParams{}, err
	}
	authorizedSigner, err := parsePayloadPubkey(payload.AuthorizedSigner, "authorizedSigner")
	if err != nil {
		return program.OpenChannelParams{}, err
	}
	if payload.Salt == nil {
		return program.OpenChannelParams{}, fmt.Errorf("payment-channel open missing salt")
	}
	if payload.GracePeriod == nil {
		return program.OpenChannelParams{}, fmt.Errorf("payment-channel open missing gracePeriod")
	}
	deposit, err := payload.DepositAmount()
	if err != nil {
		return program.OpenChannelParams{}, err
	}
	tokenProgram, err := s.expectedTokenProgram()
	if err != nil {
		return program.OpenChannelParams{}, err
	}
	programID := s.programID()
	expectedPayee, err := parsePayloadPubkey(s.config.Recipient, "recipient")
	if err != nil {
		return program.OpenChannelParams{}, err
	}
	expectedMint, err := s.expectedMint()
	if err != nil {
		return program.OpenChannelParams{}, err
	}
	if !payee.Equals(expectedPayee) {
		return program.OpenChannelParams{}, fmt.Errorf("payment-channel open payee does not match challenge recipient")
	}
	if !mint.Equals(expectedMint) {
		return program.OpenChannelParams{}, fmt.Errorf("payment-channel open mint does not match challenge currency")
	}
	recipients := make([]program.Distribution, 0, len(s.config.Splits))
	for _, split := range s.config.Splits {
		recipients = append(recipients, program.Distribution{Recipient: split.Recipient, Bps: split.Bps})
	}
	params := program.OpenChannelParams{
		Payer:            payer,
		Payee:            payee,
		Mint:             mint,
		AuthorizedSigner: authorizedSigner,
		Salt:             *payload.Salt,
		Deposit:          deposit,
		GracePeriod:      *payload.GracePeriod,
		Recipients:       recipients,
		TokenProgram:     tokenProgram,
		ProgramID:        programID,
	}
	addresses, err := program.DeriveChannelAddresses(params)
	if err != nil {
		return program.OpenChannelParams{}, err
	}
	channel, err := parsePayloadPubkey(payload.ChannelID, "channelId")
	if err != nil {
		return program.OpenChannelParams{}, err
	}
	if !channel.Equals(addresses.Channel) {
		return program.OpenChannelParams{}, fmt.Errorf("payment-channel open channelId does not match derived channel PDA")
	}
	return params, nil
}

// PaymentChannelOpenInstruction builds the exact open instruction for a payload.
func (s *SessionServer) PaymentChannelOpenInstruction(payload intents.OpenPayload) (solana.Instruction, error) {
	params, err := s.PaymentChannelOpenParams(payload)
	if err != nil {
		return nil, err
	}
	return program.BuildOpenInstruction(params)
}

// VerifyVoucher verifies a voucher, advances the watermark atomically, and
// returns the new cumulative. Rejects unknown channels, non-increasing
// cumulatives (unless exact idempotent replay), over-deposit, invalid
// signatures, below-min-delta increments, and vouchers after close.
func (s *SessionServer) VerifyVoucher(ctx context.Context, payload intents.VoucherPayload) (uint64, error) {
	voucher := payload.Voucher
	channelID := voucher.Data.ChannelID
	newCumulative, err := strconv.ParseUint(voucher.Data.Cumulative, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid cumulative in voucher")
	}
	state, ok, err := s.store.GetChannel(ctx, channelID)
	if err != nil {
		return 0, err
	}
	if !ok {
		return 0, fmt.Errorf("channel %s not found", channelID)
	}
	if state.Finalized {
		return 0, fmt.Errorf("channel is already finalized")
	}
	if state.CloseRequestedAt != nil {
		return 0, fmt.Errorf("channel close is pending - no further vouchers accepted")
	}
	// Idempotent replay: same cumulative and same signature.
	if newCumulative == state.Cumulative && state.HighestVoucherSignature == voucher.Signature {
		if err := verifyVoucherSignature(voucher, state.AuthorizedSigner); err != nil {
			return 0, err
		}
		return newCumulative, nil
	}
	if newCumulative <= state.Cumulative {
		return 0, fmt.Errorf("voucher cumulative %d must exceed watermark %d", newCumulative, state.Cumulative)
	}
	if newCumulative > state.Deposit {
		return 0, fmt.Errorf("voucher cumulative %d exceeds deposit %d", newCumulative, state.Deposit)
	}
	if s.config.MinVoucherDelta > 0 {
		if delta := newCumulative - state.Cumulative; delta < s.config.MinVoucherDelta {
			return 0, fmt.Errorf("voucher delta %d is below minimum %d", delta, s.config.MinVoucherDelta)
		}
	}
	if err := verifyVoucherSignature(voucher, state.AuthorizedSigner); err != nil {
		return 0, err
	}
	expiresAt := voucher.Data.ExpiresAt
	next, err := s.store.UpdateChannel(ctx, channelID, func(st core.ChannelState, present bool) (core.ChannelState, error) {
		if !present {
			return core.ChannelState{}, fmt.Errorf("channel not found")
		}
		if st.Finalized {
			return core.ChannelState{}, fmt.Errorf("channel is already finalized")
		}
		if st.CloseRequestedAt != nil {
			return core.ChannelState{}, fmt.Errorf("channel close is pending - no further vouchers accepted")
		}
		if newCumulative == st.Cumulative && st.HighestVoucherSignature == voucher.Signature {
			return st, nil
		}
		if newCumulative <= st.Cumulative {
			return core.ChannelState{}, fmt.Errorf("concurrent update: watermark advanced")
		}
		st.Cumulative = newCumulative
		st.HighestVoucherSignature = voucher.Signature
		expiry := expiresAt
		st.HighestVoucherExpiresAt = &expiry
		return st, nil
	})
	if err != nil {
		return 0, err
	}
	return next.Cumulative, nil
}

// ProcessTopUp atomically raises the channel's deposit cap. NewDeposit must
// exceed the current deposit and stay within MaxCap.
func (s *SessionServer) ProcessTopUp(ctx context.Context, payload intents.TopUpPayload) (core.ChannelState, error) {
	newDeposit, err := strconv.ParseUint(payload.NewDeposit, 10, 64)
	if err != nil {
		return core.ChannelState{}, fmt.Errorf("invalid newDeposit")
	}
	maxCap := s.config.MaxCap
	return s.store.UpdateChannel(ctx, payload.ChannelID, func(st core.ChannelState, present bool) (core.ChannelState, error) {
		if !present {
			return core.ChannelState{}, fmt.Errorf("channel %s not found", payload.ChannelID)
		}
		if newDeposit <= st.Deposit {
			return core.ChannelState{}, fmt.Errorf("new deposit %d must exceed current deposit %d", newDeposit, st.Deposit)
		}
		if newDeposit > maxCap {
			return core.ChannelState{}, fmt.Errorf("new deposit %d exceeds max cap %d", newDeposit, maxCap)
		}
		st.Deposit = newDeposit
		return st, nil
	})
}

// DeliveryRequest reserves capacity for a metered delivery.
type DeliveryRequest struct {
	SessionID  string
	Amount     uint64
	DeliveryID string
	CommitURL  string
	Proof      string
	ExpiresAt  *int64
}

// BeginDelivery reserves capacity for a delivered message and returns the
// metering directive the client must commit after processing it.
func (s *SessionServer) BeginDelivery(ctx context.Context, request DeliveryRequest) (intents.MeteringDirective, error) {
	if request.Amount == 0 {
		return intents.MeteringDirective{}, fmt.Errorf("delivery amount must be greater than zero")
	}
	expiresAt := intents.DefaultSessionExpiresAt
	if request.ExpiresAt != nil {
		expiresAt = *request.ExpiresAt
	}
	var directive intents.MeteringDirective
	_, err := s.store.UpdateChannel(ctx, request.SessionID, func(st core.ChannelState, present bool) (core.ChannelState, error) {
		if !present {
			return core.ChannelState{}, fmt.Errorf("channel %s not found", request.SessionID)
		}
		if st.Finalized {
			return core.ChannelState{}, fmt.Errorf("channel is already finalized")
		}
		if st.CloseRequestedAt != nil {
			return core.ChannelState{}, fmt.Errorf("channel close is pending - no further deliveries accepted")
		}
		var pendingTotal uint64
		for _, p := range st.PendingDeliveries {
			pendingTotal += p.Amount
		}
		if st.Cumulative+pendingTotal+request.Amount > st.Deposit {
			return core.ChannelState{}, fmt.Errorf("delivery amount %d exceeds available deposit", request.Amount)
		}
		sequence := st.NextDeliverySequence + 1
		deliveryID := request.DeliveryID
		if deliveryID == "" {
			deliveryID = fmt.Sprintf("%s:%d", request.SessionID, sequence)
		}
		for _, p := range st.PendingDeliveries {
			if p.DeliveryID == deliveryID {
				return core.ChannelState{}, fmt.Errorf("delivery %s already exists", deliveryID)
			}
		}
		for _, c := range st.CommittedDeliveries {
			if c.DeliveryID == deliveryID {
				return core.ChannelState{}, fmt.Errorf("delivery %s already exists", deliveryID)
			}
		}
		st.NextDeliverySequence = sequence
		st.PendingDeliveries = append(st.PendingDeliveries, core.PendingDelivery{
			DeliveryID: deliveryID,
			Amount:     request.Amount,
			Sequence:   sequence,
			ExpiresAt:  expiresAt,
		})
		directive = intents.MeteringDirective{
			DeliveryID: deliveryID,
			SessionID:  request.SessionID,
			Amount:     strconv.FormatUint(request.Amount, 10),
			Currency:   s.config.Currency,
			Sequence:   sequence,
			ExpiresAt:  expiresAt,
			CommitURL:  request.CommitURL,
			Proof:      request.Proof,
		}
		return st, nil
	})
	if err != nil {
		return intents.MeteringDirective{}, err
	}
	return directive, nil
}

// ProcessCommit commits a reserved delivery by verifying the voucher and
// advancing the settled watermark. A duplicate deliveryId returns a Replayed
// receipt rather than re-settling.
func (s *SessionServer) ProcessCommit(ctx context.Context, payload intents.CommitPayload) (intents.CommitReceipt, error) {
	channelID := payload.Voucher.Data.ChannelID
	newCumulative, err := strconv.ParseUint(payload.Voucher.Data.Cumulative, 10, 64)
	if err != nil {
		return intents.CommitReceipt{}, fmt.Errorf("invalid cumulative in commit voucher")
	}
	state, ok, err := s.store.GetChannel(ctx, channelID)
	if err != nil {
		return intents.CommitReceipt{}, err
	}
	if !ok {
		return intents.CommitReceipt{}, fmt.Errorf("channel %s not found", channelID)
	}
	for _, committed := range state.CommittedDeliveries {
		if committed.DeliveryID == payload.DeliveryID {
			if committed.Cumulative == newCumulative && committed.VoucherSignature == payload.Voucher.Signature {
				if err := verifyVoucherSignature(payload.Voucher, state.AuthorizedSigner); err != nil {
					return intents.CommitReceipt{}, err
				}
				return intents.CommitReceipt{
					DeliveryID: payload.DeliveryID,
					SessionID:  channelID,
					Amount:     strconv.FormatUint(committed.Amount, 10),
					Cumulative: strconv.FormatUint(committed.Cumulative, 10),
					Status:     intents.CommitStatusReplayed,
				}, nil
			}
			return intents.CommitReceipt{}, fmt.Errorf("delivery %s was already committed with different voucher", payload.DeliveryID)
		}
	}
	now := time.Now().Unix()
	if err := verifyVoucherSignature(payload.Voucher, state.AuthorizedSigner); err != nil {
		return intents.CommitReceipt{}, err
	}
	var amount, cumulative uint64
	var status intents.CommitStatus
	_, err = s.store.UpdateChannel(ctx, channelID, func(st core.ChannelState, present bool) (core.ChannelState, error) {
		if !present {
			return core.ChannelState{}, fmt.Errorf("channel %s not found", channelID)
		}
		if st.Finalized {
			return core.ChannelState{}, fmt.Errorf("channel is already finalized")
		}
		if st.CloseRequestedAt != nil {
			return core.ChannelState{}, fmt.Errorf("channel close is pending - no further commits accepted")
		}
		for _, committed := range st.CommittedDeliveries {
			if committed.DeliveryID == payload.DeliveryID {
				if committed.Cumulative == newCumulative && committed.VoucherSignature == payload.Voucher.Signature {
					amount, cumulative, status = committed.Amount, committed.Cumulative, intents.CommitStatusReplayed
					return st, nil
				}
				return core.ChannelState{}, fmt.Errorf("delivery %s was already committed with different voucher", payload.DeliveryID)
			}
		}
		idx := -1
		for i, p := range st.PendingDeliveries {
			if p.DeliveryID == payload.DeliveryID {
				idx = i
				break
			}
		}
		if idx < 0 {
			return core.ChannelState{}, fmt.Errorf("delivery %s not found", payload.DeliveryID)
		}
		pending := st.PendingDeliveries[idx]
		if pending.ExpiresAt <= now {
			return core.ChannelState{}, fmt.Errorf("delivery %s has expired", payload.DeliveryID)
		}
		if newCumulative <= st.Cumulative {
			return core.ChannelState{}, fmt.Errorf("commit cumulative %d must exceed watermark %d", newCumulative, st.Cumulative)
		}
		actualAmount := newCumulative - st.Cumulative
		if actualAmount > pending.Amount {
			return core.ChannelState{}, fmt.Errorf("commit amount %d exceeds reserved amount %d", actualAmount, pending.Amount)
		}
		st.PendingDeliveries = append(st.PendingDeliveries[:idx], st.PendingDeliveries[idx+1:]...)
		st.Cumulative = newCumulative
		st.HighestVoucherSignature = payload.Voucher.Signature
		expiry := payload.Voucher.Data.ExpiresAt
		st.HighestVoucherExpiresAt = &expiry
		st.CommittedDeliveries = append(st.CommittedDeliveries, core.CommittedDelivery{
			DeliveryID:       payload.DeliveryID,
			Amount:           actualAmount,
			Cumulative:       newCumulative,
			VoucherSignature: payload.Voucher.Signature,
		})
		amount, cumulative, status = actualAmount, newCumulative, intents.CommitStatusCommitted
		return st, nil
	})
	if err != nil {
		return intents.CommitReceipt{}, err
	}
	return intents.CommitReceipt{
		DeliveryID: payload.DeliveryID,
		SessionID:  channelID,
		Amount:     strconv.FormatUint(amount, 10),
		Cumulative: strconv.FormatUint(cumulative, 10),
		Status:     status,
	}, nil
}

// FinalizeParams holds the parameters needed for on-chain settlement.
type FinalizeParams struct {
	ChannelID        solana.PublicKey
	AuthorizedSigner *solana.PublicKey
	Payer            *solana.PublicKey
	Mint             *solana.PublicKey
	ProgramID        solana.PublicKey
	Settled          uint64
	VoucherSignature string
	VoucherExpiresAt *int64
	Recipient        solana.PublicKey
	Splits           []SessionSplit
	DistributionHash [32]byte
}

// ProcessClose sets close-pending atomically, applies a final voucher if
// provided, then returns the finalize parameters.
func (s *SessionServer) ProcessClose(ctx context.Context, payload intents.ClosePayload) (FinalizeParams, error) {
	now := time.Now().Unix()
	voucher := payload.Voucher
	authorizedSigner := ""
	if voucher != nil {
		st, ok, err := s.store.GetChannel(ctx, payload.ChannelID)
		if err != nil {
			return FinalizeParams{}, err
		}
		if ok {
			authorizedSigner = st.AuthorizedSigner
		}
	}
	_, err := s.store.UpdateChannel(ctx, payload.ChannelID, func(st core.ChannelState, present bool) (core.ChannelState, error) {
		if !present {
			return core.ChannelState{}, fmt.Errorf("channel not found")
		}
		if st.Finalized {
			return core.ChannelState{}, fmt.Errorf("channel is already finalized")
		}
		if st.CloseRequestedAt != nil {
			return core.ChannelState{}, fmt.Errorf("close already requested")
		}
		if voucher != nil {
			cumulative, err := strconv.ParseUint(voucher.Data.Cumulative, 10, 64)
			if err != nil {
				return core.ChannelState{}, fmt.Errorf("invalid cumulative")
			}
			if cumulative <= st.Cumulative {
				if !(cumulative == st.Cumulative && st.HighestVoucherSignature == voucher.Signature) {
					return core.ChannelState{}, fmt.Errorf("final voucher cumulative %d must exceed watermark %d", cumulative, st.Cumulative)
				}
				if st.HighestVoucherExpiresAt == nil {
					expiry := voucher.Data.ExpiresAt
					st.HighestVoucherExpiresAt = &expiry
				}
			} else {
				if cumulative > st.Deposit {
					return core.ChannelState{}, fmt.Errorf("final voucher exceeds deposit")
				}
				if err := verifyVoucherSignature(*voucher, authorizedSigner); err != nil {
					return core.ChannelState{}, err
				}
				st.Cumulative = cumulative
				st.HighestVoucherSignature = voucher.Signature
				expiry := voucher.Data.ExpiresAt
				st.HighestVoucherExpiresAt = &expiry
			}
		}
		closeAt := now
		st.CloseRequestedAt = &closeAt
		return st, nil
	})
	if err != nil {
		return FinalizeParams{}, err
	}
	return s.FinalizeParams(ctx, payload.ChannelID)
}

// FinalizeParams returns the finalize parameters for a channel.
func (s *SessionServer) FinalizeParams(ctx context.Context, channelID string) (FinalizeParams, error) {
	state, ok, err := s.store.GetChannel(ctx, channelID)
	if err != nil {
		return FinalizeParams{}, err
	}
	if !ok {
		return FinalizeParams{}, fmt.Errorf("channel %s not found", channelID)
	}
	channelPubkey, err := solana.PublicKeyFromBase58(channelID)
	if err != nil {
		return FinalizeParams{}, err
	}
	recipientPubkey, err := solana.PublicKeyFromBase58(s.config.Recipient)
	if err != nil {
		return FinalizeParams{}, err
	}
	params := FinalizeParams{
		ChannelID:        channelPubkey,
		ProgramID:        s.programID(),
		Settled:          state.Cumulative,
		VoucherSignature: state.HighestVoucherSignature,
		VoucherExpiresAt: state.HighestVoucherExpiresAt,
		Recipient:        recipientPubkey,
		Splits:           append([]SessionSplit(nil), s.config.Splits...),
	}
	if signer, err := solana.PublicKeyFromBase58(state.AuthorizedSigner); err == nil {
		params.AuthorizedSigner = &signer
	}
	if state.Operator != "" {
		if payer, err := solana.PublicKeyFromBase58(state.Operator); err == nil {
			params.Payer = &payer
		}
	}
	if mint, err := s.expectedMint(); err == nil {
		params.Mint = &mint
	}
	recipients := make([]program.Distribution, 0, len(s.config.Splits))
	for _, split := range s.config.Splits {
		recipients = append(recipients, program.Distribution{Recipient: split.Recipient, Bps: split.Bps})
	}
	params.DistributionHash = program.DistributionHash(recipients)
	return params, nil
}

// MarkFinalized marks a channel as finalized after the on-chain finalize tx.
func (s *SessionServer) MarkFinalized(ctx context.Context, channelID string) error {
	_, err := s.store.UpdateChannel(ctx, channelID, func(st core.ChannelState, present bool) (core.ChannelState, error) {
		if !present {
			return core.ChannelState{}, fmt.Errorf("channel %s not found", channelID)
		}
		st.Finalized = true
		return st, nil
	})
	return err
}

func (s *SessionServer) programID() solana.PublicKey {
	if s.config.ProgramID != "" {
		if pk, err := solana.PublicKeyFromBase58(s.config.ProgramID); err == nil {
			return pk
		}
	}
	return program.DefaultProgramID()
}

func (s *SessionServer) expectedMint() (solana.PublicKey, error) {
	resolved := paycore.ResolveMint(s.config.Currency, s.config.Network)
	if resolved == "" {
		return solana.PublicKey{}, fmt.Errorf("payment-channel sessions require an SPL token")
	}
	return solana.PublicKeyFromBase58(resolved)
}

func (s *SessionServer) expectedTokenProgram() (solana.PublicKey, error) {
	return solana.PublicKeyFromBase58(paycore.DefaultTokenProgramForCurrency(s.config.Currency, s.config.Network))
}

func parsePayloadPubkey(value, field string) (solana.PublicKey, error) {
	if value == "" {
		return solana.PublicKey{}, fmt.Errorf("payment-channel open missing %s", field)
	}
	pk, err := solana.PublicKeyFromBase58(value)
	if err != nil {
		return solana.PublicKey{}, fmt.Errorf("invalid payment-channel %s: %w", field, err)
	}
	return pk, nil
}

// verifyVoucherSignature verifies the Ed25519 voucher signature against the
// authorized signer and rejects expired vouchers.
func verifyVoucherSignature(voucher intents.SignedVoucher, authorizedSigner string) error {
	if voucher.Data.ExpiresAt <= time.Now().Unix() {
		return fmt.Errorf("voucher has expired")
	}
	message, err := voucher.Data.MessageBytes()
	if err != nil {
		return err
	}
	signature, err := solana.SignatureFromBase58(voucher.Signature)
	if err != nil {
		return fmt.Errorf("invalid signature encoding: %w", err)
	}
	signer, err := solana.PublicKeyFromBase58(authorizedSigner)
	if err != nil {
		return fmt.Errorf("invalid authorizedSigner: %w", err)
	}
	if !ed25519.Verify(ed25519.PublicKey(signer[:]), message, signature[:]) {
		return fmt.Errorf("voucher signature verification failed")
	}
	return nil
}
