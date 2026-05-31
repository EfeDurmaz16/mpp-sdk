package core

import (
	"context"
	"errors"
	"sync"
)

// PendingDelivery is a server-reserved metered delivery awaiting commit.
type PendingDelivery struct {
	DeliveryID string `json:"deliveryId"`
	Amount     uint64 `json:"amount"`
	Sequence   uint64 `json:"sequence"`
	ExpiresAt  int64  `json:"expiresAt"`
}

// CommittedDelivery is a committed delivery kept for idempotent commit replay.
type CommittedDelivery struct {
	DeliveryID       string `json:"deliveryId"`
	Amount           uint64 `json:"amount"`
	Cumulative       uint64 `json:"cumulative"`
	VoucherSignature string `json:"voucherSignature"`
}

// ChannelState is the persisted state of a payment channel, managed by the
// session server. Mirrors ChannelState in the Rust spine (store.rs).
type ChannelState struct {
	// ChannelID is the on-chain channel address (push) or token account /
	// FixedDelegation PDA (pull), base58.
	ChannelID string `json:"channelId"`
	// AuthorizedSigner is the pubkey authorized to sign vouchers (base58).
	AuthorizedSigner string `json:"authorizedSigner"`
	// Deposit is the total deposit / approved amount in base units.
	Deposit uint64 `json:"deposit"`
	// Cumulative is the highest cumulative amount accepted (settled watermark).
	Cumulative uint64 `json:"cumulative"`
	// Finalized is true once the channel has been finalized on-chain.
	Finalized bool `json:"finalized"`
	// HighestVoucherSignature is the signature of the highest accepted voucher.
	HighestVoucherSignature string `json:"highestVoucherSignature,omitempty"`
	// HighestVoucherExpiresAt is the expiry of the highest accepted voucher.
	HighestVoucherExpiresAt *int64 `json:"highestVoucherExpiresAt,omitempty"`
	// CloseRequestedAt is the unix second when cooperative close was requested.
	CloseRequestedAt *int64 `json:"closeRequestedAt,omitempty"`
	// Operator is the pull-mode client wallet pubkey (push: payer), base58.
	Operator string `json:"operator,omitempty"`
	// NextDeliverySequence is the next server-side metered delivery sequence.
	NextDeliverySequence uint64 `json:"nextDeliverySequence"`
	// PendingDeliveries are reserved but not yet committed.
	PendingDeliveries []PendingDelivery `json:"pendingDeliveries,omitempty"`
	// CommittedDeliveries are recently committed, kept for idempotent replay.
	CommittedDeliveries []CommittedDelivery `json:"committedDeliveries,omitempty"`
}

// Clone returns a deep copy so callers cannot mutate stored state in place.
func (s ChannelState) Clone() ChannelState {
	out := s
	if s.HighestVoucherExpiresAt != nil {
		v := *s.HighestVoucherExpiresAt
		out.HighestVoucherExpiresAt = &v
	}
	if s.CloseRequestedAt != nil {
		v := *s.CloseRequestedAt
		out.CloseRequestedAt = &v
	}
	if len(s.PendingDeliveries) > 0 {
		out.PendingDeliveries = append([]PendingDelivery(nil), s.PendingDeliveries...)
	}
	if len(s.CommittedDeliveries) > 0 {
		out.CommittedDeliveries = append([]CommittedDelivery(nil), s.CommittedDeliveries...)
	}
	return out
}

// ErrChannelNotFound is returned when a channel id is absent from the store.
var ErrChannelNotFound = errors.New("channel not found")

// ChannelStore is an atomic store for channel state. UpdateChannel MUST be
// atomic so concurrent voucher verification cannot interleave and double-spend.
type ChannelStore interface {
	// GetChannel returns the state and ok=false when absent.
	GetChannel(ctx context.Context, channelID string) (ChannelState, bool, error)
	// PutChannel stores (overwriting) the state for channelID.
	PutChannel(ctx context.Context, channelID string, state ChannelState) error
	// UpdateChannel atomically reads, transforms, and writes channel state.
	// The updater receives the current state (ok=false if absent) and returns
	// the new state or an error that aborts the write.
	UpdateChannel(ctx context.Context, channelID string, updater func(ChannelState, bool) (ChannelState, error)) (ChannelState, error)
}

// MemoryChannelStore is an in-memory ChannelStore backed by a mutex.
type MemoryChannelStore struct {
	mu   sync.Mutex
	data map[string]ChannelState
}

// NewMemoryChannelStore creates a MemoryChannelStore.
func NewMemoryChannelStore() *MemoryChannelStore {
	return &MemoryChannelStore{data: map[string]ChannelState{}}
}

// GetChannel returns a deep copy of the stored state.
func (s *MemoryChannelStore) GetChannel(_ context.Context, channelID string) (ChannelState, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, ok := s.data[channelID]
	if !ok {
		return ChannelState{}, false, nil
	}
	return state.Clone(), true, nil
}

// PutChannel stores a deep copy of state under channelID.
func (s *MemoryChannelStore) PutChannel(_ context.Context, channelID string, state ChannelState) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data[channelID] = state.Clone()
	return nil
}

// UpdateChannel atomically applies updater under the store mutex.
func (s *MemoryChannelStore) UpdateChannel(
	_ context.Context,
	channelID string,
	updater func(ChannelState, bool) (ChannelState, error),
) (ChannelState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	current, ok := s.data[channelID]
	var input ChannelState
	if ok {
		input = current.Clone()
	}
	next, err := updater(input, ok)
	if err != nil {
		return ChannelState{}, err
	}
	s.data[channelID] = next.Clone()
	return next.Clone(), nil
}
