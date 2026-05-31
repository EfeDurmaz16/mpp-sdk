package client

import (
	"context"
	"fmt"

	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
)

// CommitTransport sends commit payloads to the server. HTTP clients, queues,
// and in-process tests can all implement it. The directive is passed alongside
// the payload so transports can use commitUrl/proof routing hints without those
// fields being repeated in the signed commit body.
type CommitTransport interface {
	Commit(ctx context.Context, directive intents.MeteringDirective, payload intents.CommitPayload) (intents.CommitReceipt, error)
}

// SessionConsumer wraps an ActiveSession so applications can process delivered
// messages and call Commit instead of manually signing and posting vouchers.
// Mirrors SessionConsumer in the Rust spine (client/session_consumer.rs).
type SessionConsumer struct {
	session   *ActiveSession
	transport CommitTransport
}

// NewSessionConsumer creates a consumer over a session and commit transport.
func NewSessionConsumer(session *ActiveSession, transport CommitTransport) *SessionConsumer {
	return &SessionConsumer{session: session, transport: transport}
}

// Session returns the underlying active session.
func (c *SessionConsumer) Session() *ActiveSession { return c.session }

// CommitDirective signs a voucher for the directive amount, sends the commit,
// and advances the local watermark only after the transport accepts it. A
// failed commit leaves the local watermark untouched so the same directive can
// be retried without drift.
func (c *SessionConsumer) CommitDirective(ctx context.Context, directive intents.MeteringDirective) (intents.CommitReceipt, error) {
	if err := c.validateDirective(directive); err != nil {
		return intents.CommitReceipt{}, err
	}
	amount, err := directive.AmountBaseUnits()
	if err != nil {
		return intents.CommitReceipt{}, err
	}
	if amount == 0 {
		return intents.CommitReceipt{}, fmt.Errorf("metered delivery amount must be greater than zero")
	}
	voucher, err := c.session.PrepareIncrement(amount)
	if err != nil {
		return intents.CommitReceipt{}, err
	}
	payload := intents.CommitPayload{DeliveryID: directive.DeliveryID, Voucher: voucher}
	receipt, err := c.transport.Commit(ctx, directive, payload)
	if err != nil {
		return intents.CommitReceipt{}, err
	}
	if err := c.session.RecordVoucher(voucher); err != nil {
		return intents.CommitReceipt{}, err
	}
	return receipt, nil
}

func (c *SessionConsumer) validateDirective(directive intents.MeteringDirective) error {
	channelID := c.session.ChannelIDStr()
	if directive.SessionID != channelID {
		return fmt.Errorf("metered delivery session %s does not match active session %s", directive.SessionID, channelID)
	}
	return nil
}

// Accept validates a metered envelope and returns a delivery handle.
func (c *SessionConsumer) Accept(directive intents.MeteringDirective) (MeteredDelivery, error) {
	if err := c.validateDirective(directive); err != nil {
		return MeteredDelivery{}, err
	}
	return MeteredDelivery{consumer: c, metering: directive}, nil
}

// MeteredDelivery is a delivery handle exposing the metering directive and the
// Commit/Ack action that settles it.
type MeteredDelivery struct {
	consumer *SessionConsumer
	metering intents.MeteringDirective
}

// Metering returns the metering directive for the delivery.
func (d MeteredDelivery) Metering() intents.MeteringDirective { return d.metering }

// Ack signs and sends the commit for the delivery.
func (d MeteredDelivery) Ack(ctx context.Context) (intents.CommitReceipt, error) {
	return d.consumer.CommitDirective(ctx, d.metering)
}

// Commit is an alias for Ack.
func (d MeteredDelivery) Commit(ctx context.Context) (intents.CommitReceipt, error) {
	return d.Ack(ctx)
}
