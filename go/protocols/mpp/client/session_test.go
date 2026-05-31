package client

import (
	"crypto/ed25519"
	"testing"

	solana "github.com/gagliardetto/solana-go"

	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
)

// seededSigner returns a deterministic signer from a fixed 32-byte seed,
// mirroring the make_signer helper in the Rust client/session tests.
func seededSigner(seed byte) solana.PrivateKey {
	b := make([]byte, 32)
	for i := range b {
		b[i] = seed
	}
	return solana.PrivateKey(ed25519.NewKeyFromSeed(b))
}

func newTestSession() *ActiveSession {
	channel := solana.NewWallet().PublicKey()
	return NewActiveSession(channel, seededSigner(42))
}

func TestSignIncrementIncreasesCumulative(t *testing.T) {
	s := newTestSession()
	if s.Cumulative() != 0 {
		t.Fatalf("initial cumulative = %d", s.Cumulative())
	}
	v, err := s.SignIncrement(100)
	if err != nil {
		t.Fatal(err)
	}
	if s.Cumulative() != 100 || v.Data.Cumulative != "100" || *v.Data.Nonce != 1 {
		t.Fatalf("increment mismatch: cum=%d v=%+v", s.Cumulative(), v.Data)
	}
}

func TestSignVoucherRejectsNonIncreasing(t *testing.T) {
	s := newTestSession()
	if _, err := s.SignIncrement(100); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SignVoucher(100); err == nil {
		t.Fatalf("expected non-increasing rejection")
	}
	if _, err := s.SignVoucher(50); err == nil {
		t.Fatalf("expected non-increasing rejection")
	}
}

func TestPrepareAndRecordAreSeparate(t *testing.T) {
	s := newTestSession()
	prepared, err := s.PrepareIncrement(75)
	if err != nil {
		t.Fatal(err)
	}
	if s.Cumulative() != 0 {
		t.Fatalf("prepare should not advance watermark")
	}
	if err := s.RecordVoucher(prepared); err != nil {
		t.Fatal(err)
	}
	if s.Cumulative() != 75 {
		t.Fatalf("record should advance to 75, got %d", s.Cumulative())
	}
	if err := s.RecordVoucher(prepared); err == nil {
		t.Fatalf("re-record should fail")
	}
}

func TestNonceIncrementsPerVoucher(t *testing.T) {
	s := newTestSession()
	v1, _ := s.SignIncrement(10)
	v2, _ := s.SignIncrement(10)
	if *v1.Data.Nonce != 1 || *v2.Data.Nonce != 2 {
		t.Fatalf("nonce sequence mismatch: %d %d", *v1.Data.Nonce, *v2.Data.Nonce)
	}
}

// Golden vector: a voucher signed by the session must verify under the session
// signer's public key over the program Borsh voucher bytes. This locks the
// signing-byte layout used cross-language without a live chain.
func TestSignedVoucherVerifiesAgainstSignerKey(t *testing.T) {
	channel := solana.NewWallet().PublicKey()
	signer := seededSigner(7)
	s := NewActiveSession(channel, signer)
	voucher, err := s.SignIncrement(250)
	if err != nil {
		t.Fatal(err)
	}
	message, err := voucher.Data.MessageBytes()
	if err != nil {
		t.Fatal(err)
	}
	sig, err := solana.SignatureFromBase58(voucher.Signature)
	if err != nil {
		t.Fatal(err)
	}
	pub := signer.PublicKey()
	if !ed25519.Verify(ed25519.PublicKey(pub[:]), message, sig[:]) {
		t.Fatalf("voucher signature did not verify against signer key")
	}
	if voucher.Data.ChannelID != channel.String() {
		t.Fatalf("voucher channel id mismatch")
	}
}

func TestOpenActionFields(t *testing.T) {
	s := newTestSession()
	action := s.OpenAction(1_000_000, "txsig123")
	if action.Action != intents.ActionOpen || action.Open == nil {
		t.Fatalf("open action shape mismatch")
	}
	if action.Open.Mode != intents.SessionModePush || action.Open.Deposit != "1000000" || action.Open.Signature != "txsig123" {
		t.Fatalf("open action fields mismatch: %+v", action.Open)
	}
	if action.Open.AuthorizedSigner != s.AuthorizedSigner() {
		t.Fatalf("authorized signer mismatch")
	}
}

func TestOpenPullActionFields(t *testing.T) {
	s := newTestSession()
	action := s.OpenPullAction(5_000_000, "wallet123", "approvesig")
	if action.Open.Mode != intents.SessionModePull || action.Open.ApprovedAmount != "5000000" || action.Open.Owner != "wallet123" {
		t.Fatalf("pull open fields mismatch: %+v", action.Open)
	}
	if action.Open.TokenAccount != s.ChannelIDStr() {
		t.Fatalf("pull token account should be channel id")
	}
}

func TestTopUpActionFields(t *testing.T) {
	s := newTestSession()
	action := s.TopUpAction(5_000_000, "topuptx")
	if action.Action != intents.ActionTopUp || action.TopUp.NewDeposit != "5000000" || action.TopUp.Signature != "topuptx" {
		t.Fatalf("topup action mismatch: %+v", action.TopUp)
	}
}

func TestCloseActionWithAndWithoutVoucher(t *testing.T) {
	s := newTestSession()
	action, err := s.CloseAction(nil)
	if err != nil {
		t.Fatal(err)
	}
	if action.Close.Voucher != nil {
		t.Fatalf("close without increment should omit voucher")
	}

	s2 := newTestSession()
	if _, err := s2.SignIncrement(100); err != nil {
		t.Fatal(err)
	}
	final := uint64(50)
	action2, err := s2.CloseAction(&final)
	if err != nil {
		t.Fatal(err)
	}
	if action2.Close.Voucher == nil || action2.Close.Voucher.Data.Cumulative != "150" {
		t.Fatalf("close with final increment mismatch")
	}
}

func TestSetExpiresAt(t *testing.T) {
	channel := solana.NewWallet().PublicKey()
	s := NewActiveSessionWithExpiry(channel, seededSigner(42), 1234)
	v, _ := s.PrepareIncrement(10)
	if v.Data.ExpiresAt != 1234 {
		t.Fatalf("expiry = %d, want 1234", v.Data.ExpiresAt)
	}
	s.SetExpiresAt(5678)
	v2, _ := s.PrepareIncrement(10)
	if v2.Data.ExpiresAt != 5678 {
		t.Fatalf("expiry = %d, want 5678", v2.Data.ExpiresAt)
	}
}
