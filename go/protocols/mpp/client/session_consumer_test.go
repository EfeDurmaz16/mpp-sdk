package client

import (
	"context"
	"errors"
	"testing"

	solana "github.com/gagliardetto/solana-go"

	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
)

type recordingTransport struct {
	commits []intents.CommitPayload
	fail    bool
}

func (r *recordingTransport) Commit(_ context.Context, directive intents.MeteringDirective, payload intents.CommitPayload) (intents.CommitReceipt, error) {
	if r.fail {
		return intents.CommitReceipt{}, errors.New("commit failed")
	}
	r.commits = append(r.commits, payload)
	return intents.CommitReceipt{
		DeliveryID: directive.DeliveryID,
		SessionID:  directive.SessionID,
		Amount:     directive.Amount,
		Cumulative: payload.Voucher.Data.Cumulative,
		Status:     intents.CommitStatusCommitted,
	}, nil
}

func directive(sessionID string, amount uint64) intents.MeteringDirective {
	return intents.MeteringDirective{
		DeliveryID: "d1",
		SessionID:  sessionID,
		Amount:     itoa(amount),
		Currency:   "USDC",
		Sequence:   1,
		ExpiresAt:  DefaultVoucherExpiresAt,
	}
}

func itoa(v uint64) string {
	if v == 0 {
		return "0"
	}
	var b []byte
	for v > 0 {
		b = append([]byte{byte('0' + v%10)}, b...)
		v /= 10
	}
	return string(b)
}

func TestConsumerAckCommitsAndAdvances(t *testing.T) {
	session := NewActiveSession(solana.NewWallet().PublicKey(), seededSigner(7))
	transport := &recordingTransport{}
	consumer := NewSessionConsumer(session, transport)

	delivery, err := consumer.Accept(directive(session.ChannelIDStr(), 250))
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := delivery.Ack(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Cumulative != "250" {
		t.Fatalf("receipt cumulative = %s", receipt.Cumulative)
	}
	if consumer.Session().Cumulative() != 250 {
		t.Fatalf("local watermark = %d, want 250", consumer.Session().Cumulative())
	}
	if len(transport.commits) != 1 {
		t.Fatalf("expected 1 commit, got %d", len(transport.commits))
	}
}

func TestConsumerRejectsWrongSession(t *testing.T) {
	session := NewActiveSession(solana.NewWallet().PublicKey(), seededSigner(7))
	consumer := NewSessionConsumer(session, &recordingTransport{})
	if _, err := consumer.Accept(directive("other-session", 1)); err == nil {
		t.Fatalf("expected wrong-session rejection")
	}
}

func TestConsumerRejectsZeroAmount(t *testing.T) {
	session := NewActiveSession(solana.NewWallet().PublicKey(), seededSigner(7))
	consumer := NewSessionConsumer(session, &recordingTransport{})
	if _, err := consumer.CommitDirective(context.Background(), directive(session.ChannelIDStr(), 0)); err == nil {
		t.Fatalf("expected zero-amount rejection")
	}
}

func TestConsumerFailedCommitDoesNotAdvance(t *testing.T) {
	session := NewActiveSession(solana.NewWallet().PublicKey(), seededSigner(7))
	transport := &recordingTransport{fail: true}
	consumer := NewSessionConsumer(session, transport)
	if _, err := consumer.CommitDirective(context.Background(), directive(session.ChannelIDStr(), 250)); err == nil {
		t.Fatalf("expected commit failure")
	}
	if consumer.Session().Cumulative() != 0 {
		t.Fatalf("watermark should not advance on failed commit")
	}
}
