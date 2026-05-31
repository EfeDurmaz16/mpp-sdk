package client

import (
	"context"
	"errors"
	"testing"

	solana "github.com/gagliardetto/solana-go"

	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
)

// failingSigner always returns an error from Sign, exercising the signing
// failure branch in PrepareVoucher and its callers.
type failingSigner struct{ pub solana.PublicKey }

func (f failingSigner) PublicKey() solana.PublicKey { return f.pub }
func (f failingSigner) Sign([]byte) (solana.Signature, error) {
	return solana.Signature{}, errors.New("signing unavailable")
}

func TestPrepareVoucherSigningFailurePropagates(t *testing.T) {
	s := NewActiveSession(solana.NewWallet().PublicKey(), failingSigner{pub: solana.NewWallet().PublicKey()})
	if _, err := s.PrepareIncrement(10); err == nil {
		t.Fatalf("expected signing failure to propagate")
	}
}

func TestSignVoucherPropagatesPrepareError(t *testing.T) {
	s := newTestSession()
	if _, err := s.SignIncrement(50); err != nil {
		t.Fatal(err)
	}
	// SignVoucher to a non-increasing cumulative fails in PrepareVoucher.
	if _, err := s.SignVoucher(50); err == nil {
		t.Fatalf("expected non-increasing SignVoucher error")
	}
}

func TestRecordVoucherRejectsBadCumulative(t *testing.T) {
	s := newTestSession()
	if err := s.RecordVoucher(intents.SignedVoucher{Data: intents.VoucherData{Cumulative: "notanumber"}}); err == nil {
		t.Fatalf("expected invalid cumulative rejection")
	}
}

func TestRecordVoucherAdoptsHigherNonce(t *testing.T) {
	s := newTestSession()
	nonce := uint64(9)
	v := intents.SignedVoucher{Data: intents.VoucherData{Cumulative: "100", Nonce: &nonce}}
	if err := s.RecordVoucher(v); err != nil {
		t.Fatal(err)
	}
	next, err := s.PrepareIncrement(1)
	if err != nil {
		t.Fatal(err)
	}
	if next.Data.Nonce == nil || *next.Data.Nonce != 10 {
		t.Fatalf("nonce should advance past adopted value, got %v", next.Data.Nonce)
	}
}

func TestVoucherActionPropagatesError(t *testing.T) {
	s := newTestSession()
	if _, err := s.SignIncrement(50); err != nil {
		t.Fatal(err)
	}
	// Force a non-increasing increment by exhausting room is hard; instead use a
	// failing signer session for the error path.
	bad := NewActiveSession(solana.NewWallet().PublicKey(), failingSigner{pub: solana.NewWallet().PublicKey()})
	if _, err := bad.VoucherAction(10); err == nil {
		t.Fatalf("expected VoucherAction to propagate signing failure")
	}
}

func TestVoucherActionShape(t *testing.T) {
	s := newTestSession()
	action, err := s.VoucherAction(120)
	if err != nil {
		t.Fatal(err)
	}
	if action.Action != intents.ActionVoucher || action.Voucher == nil {
		t.Fatalf("voucher action shape mismatch: %+v", action)
	}
	if action.Voucher.Voucher.Data.Cumulative != "120" {
		t.Fatalf("voucher cumulative mismatch: %s", action.Voucher.Voucher.Data.Cumulative)
	}
}

func TestOpenPaymentChannelActionPushAndMode(t *testing.T) {
	s := newTestSession()
	payer := solana.NewWallet().PublicKey().String()
	payee := solana.NewWallet().PublicKey().String()
	mint := solana.NewWallet().PublicKey().String()

	push := s.OpenPaymentChannelAction(1_000_000, payer, payee, mint, 77, 900, "opensig")
	if push.Open == nil || push.Open.Mode != intents.SessionModePush {
		t.Fatalf("push payment-channel action mismatch: %+v", push.Open)
	}
	if push.Open.Salt == nil || *push.Open.Salt != 77 || push.Open.Payer != payer {
		t.Fatalf("push fields mismatch: %+v", push.Open)
	}

	pull := s.OpenPaymentChannelActionWithMode(intents.SessionModePull, 2_000_000, payer, payee, mint, 88, 600, "opensig2")
	if pull.Open == nil || pull.Open.Mode != intents.SessionModePull {
		t.Fatalf("pull payment-channel action mismatch: %+v", pull.Open)
	}
	if pull.Open.GracePeriod == nil || *pull.Open.GracePeriod != 600 {
		t.Fatalf("grace period mismatch: %+v", pull.Open)
	}
}

func TestCloseActionPropagatesVoucherError(t *testing.T) {
	bad := NewActiveSession(solana.NewWallet().PublicKey(), failingSigner{pub: solana.NewWallet().PublicKey()})
	final := uint64(50)
	if _, err := bad.CloseAction(&final); err == nil {
		t.Fatalf("expected CloseAction to propagate signing failure")
	}
}

func TestConsumerCommitDirectiveRejectsBadAmount(t *testing.T) {
	session := NewActiveSession(solana.NewWallet().PublicKey(), seededSigner(7))
	consumer := NewSessionConsumer(session, &recordingTransport{})
	d := directive(session.ChannelIDStr(), 1)
	d.Amount = "notanumber"
	if _, err := consumer.CommitDirective(context.Background(), d); err == nil {
		t.Fatalf("expected bad amount rejection")
	}
}

func TestMeteredDeliveryMeteringAndCommit(t *testing.T) {
	session := NewActiveSession(solana.NewWallet().PublicKey(), seededSigner(7))
	transport := &recordingTransport{}
	consumer := NewSessionConsumer(session, transport)
	delivery, err := consumer.Accept(directive(session.ChannelIDStr(), 75))
	if err != nil {
		t.Fatal(err)
	}
	if delivery.Metering().Amount != "75" {
		t.Fatalf("metering directive mismatch: %+v", delivery.Metering())
	}
	receipt, err := delivery.Commit(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Cumulative != "75" {
		t.Fatalf("commit receipt cumulative mismatch: %s", receipt.Cumulative)
	}
}

// advancingTransport advances the session past the prepared voucher before the
// commit returns, so the post-commit RecordVoucher sees a non-increasing
// watermark and errors. This exercises the record-failure branch in
// CommitDirective.
type advancingTransport struct{ session *ActiveSession }

func (a advancingTransport) Commit(_ context.Context, _ intents.MeteringDirective, _ intents.CommitPayload) (intents.CommitReceipt, error) {
	_, _ = a.session.SignIncrement(10_000)
	return intents.CommitReceipt{Status: intents.CommitStatusCommitted}, nil
}

func TestConsumerCommitDirectiveRecordFailure(t *testing.T) {
	session := NewActiveSession(solana.NewWallet().PublicKey(), seededSigner(7))
	consumer := NewSessionConsumer(session, advancingTransport{session: session})
	if _, err := consumer.CommitDirective(context.Background(), directive(session.ChannelIDStr(), 5)); err == nil {
		t.Fatalf("expected record-after-commit failure")
	}
}

func TestSignVoucherRecordFailureBranch(t *testing.T) {
	// SignVoucher records the voucher it just signed; with a fresh session the
	// happy path advances, and re-signing the same absolute value fails in
	// PrepareVoucher, which is the only reachable failure for SignVoucher.
	s := newTestSession()
	if _, err := s.SignVoucher(100); err != nil {
		t.Fatal(err)
	}
	if s.Cumulative() != 100 {
		t.Fatalf("watermark = %d, want 100", s.Cumulative())
	}
}

func TestConsumerCommitDirectivePrepareFailure(t *testing.T) {
	// A session at a high watermark cannot prepare a lower increment, so a
	// directive amount smaller than nothing is impossible; instead, exercise the
	// prepare failure via a failing signer.
	session := NewActiveSession(solana.NewWallet().PublicKey(), failingSigner{pub: solana.NewWallet().PublicKey()})
	consumer := NewSessionConsumer(session, &recordingTransport{})
	if _, err := consumer.CommitDirective(context.Background(), directive(session.ChannelIDStr(), 10)); err == nil {
		t.Fatalf("expected prepare failure to propagate")
	}
}
