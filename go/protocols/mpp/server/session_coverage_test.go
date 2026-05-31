package server

import (
	"context"
	"crypto/ed25519"
	"testing"
	"time"

	solana "github.com/gagliardetto/solana-go"

	mppclient "github.com/solana-foundation/pay-kit/go/protocols/mpp/client"
	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
)

// seededSignerKey returns a deterministic Ed25519 signer from a fixed seed.
func seededSignerKey(seed byte) solana.PrivateKey {
	b := make([]byte, 32)
	for i := range b {
		b[i] = seed
	}
	return solana.PrivateKey(ed25519.NewKeyFromSeed(b))
}

func TestNewSessionServerAppliesDefaults(t *testing.T) {
	s := NewSessionServer(SessionConfig{}, nil)
	req := s.BuildChallengeRequest(0)
	if req.Currency != "USDC" {
		t.Fatalf("default currency = %s", req.Currency)
	}
	if req.Decimals == nil || *req.Decimals != 6 {
		t.Fatalf("default decimals mismatch: %v", req.Decimals)
	}
	if req.Network != "mainnet-beta" {
		t.Fatalf("default network = %s", req.Network)
	}
	if req.Cap != "0" {
		t.Fatalf("cap = %s", req.Cap)
	}
}

func TestBuildChallengeRequestPullAndExtras(t *testing.T) {
	strategy := intents.PullStrategyClientVoucher
	s := NewSessionServer(SessionConfig{
		Operator:            testRecipient,
		Recipient:           testRecipient,
		MaxCap:              5_000_000,
		Currency:            "USDC",
		Network:             "localnet",
		ProgramID:           "Token22222222222222222222222222222222222222",
		MinVoucherDelta:     25,
		Splits:              []SessionSplit{{Recipient: solana.NewWallet().PublicKey(), Bps: 500}},
		Modes:               []intents.SessionMode{intents.SessionModePush, intents.SessionModePull},
		PullVoucherStrategy: &strategy,
	}, nil)
	req := s.BuildChallengeRequest(3_000_000)
	if req.ProgramID == "" {
		t.Fatalf("expected programId in challenge")
	}
	if req.MinVoucherDelta != "25" {
		t.Fatalf("minVoucherDelta = %s", req.MinVoucherDelta)
	}
	if len(req.Modes) != 2 {
		t.Fatalf("expected both modes, got %v", req.Modes)
	}
	if req.PullVoucherStrategy == nil || *req.PullVoucherStrategy != intents.PullStrategyClientVoucher {
		t.Fatalf("pull strategy missing")
	}
	if len(req.Splits) != 1 || req.Splits[0].Bps != 500 {
		t.Fatalf("splits mismatch: %+v", req.Splits)
	}
}

func TestSupportsModeEmptyConfig(t *testing.T) {
	s := &SessionServer{config: SessionConfig{}}
	if !s.supportsMode(intents.SessionModePush) {
		t.Fatalf("empty modes should support push")
	}
	if s.supportsMode(intents.SessionModePull) {
		t.Fatalf("empty modes should not support pull")
	}
}

func TestProcessOpenUsesPayerWhenOwnerEmpty(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	payload := intents.NewOpenPaymentChannel("chanX", "1000", "payerKey", testRecipient, "mint", 1, 900, "signerKey", "tx")
	payload.Owner = ""
	state, err := s.ProcessOpen(ctx, payload)
	if err != nil {
		t.Fatal(err)
	}
	if state.Operator != "payerKey" {
		t.Fatalf("operator should fall back to payer, got %q", state.Operator)
	}
}

func TestProcessOpenInvalidDeposit(t *testing.T) {
	s := makeServer()
	payload := intents.NewOpenPush("chanY", "notanumber", "signer", "tx")
	if _, err := s.ProcessOpen(context.Background(), payload); err == nil {
		t.Fatalf("expected invalid deposit error")
	}
	bad := intents.OpenPayload{Mode: intents.SessionModePush, Deposit: "10"}
	if _, err := s.ProcessOpen(context.Background(), bad); err == nil {
		t.Fatalf("expected missing channelId session id error")
	}
}

func TestPaymentChannelOpenParamsMissingFields(t *testing.T) {
	s := NewSessionServer(SessionConfig{
		Operator: testRecipient, Recipient: testRecipient, MaxCap: 10_000_000,
		Currency: "USDC", Network: "mainnet-beta",
		Modes: []intents.SessionMode{intents.SessionModePull}, PullVoucherStrategy: ptrStrategy(intents.PullStrategyClientVoucher),
	}, nil)
	base := intents.NewOpenPaymentChannelWithMode(
		intents.SessionModePull, "c", "1000",
		solana.NewWallet().PublicKey().String(), testRecipient, s.mustMint(t).String(),
		1, 900, solana.NewWallet().PublicKey().String(), "tx")

	// Missing salt.
	noSalt := base
	noSalt.Salt = nil
	if _, err := s.PaymentChannelOpenParams(noSalt); err == nil {
		t.Fatalf("expected missing salt error")
	}
	// Missing gracePeriod.
	noGrace := base
	noGrace.GracePeriod = nil
	if _, err := s.PaymentChannelOpenParams(noGrace); err == nil {
		t.Fatalf("expected missing gracePeriod error")
	}
	// Invalid payer.
	badPayer := base
	badPayer.Payer = "!!!"
	if _, err := s.PaymentChannelOpenParams(badPayer); err == nil {
		t.Fatalf("expected invalid payer error")
	}
	// Wrong mint.
	wrongMint := base
	wrongMint.Mint = solana.NewWallet().PublicKey().String()
	if _, err := s.PaymentChannelOpenParams(wrongMint); err == nil {
		t.Fatalf("expected mint mismatch error")
	}
	// Wrong channel PDA.
	wrongChannel := base
	wrongChannel.ChannelID = solana.NewWallet().PublicKey().String()
	if _, err := s.PaymentChannelOpenParams(wrongChannel); err == nil {
		t.Fatalf("expected channel PDA mismatch error")
	}
}

func TestPaymentChannelOpenInstructionError(t *testing.T) {
	s := makeServer()
	if _, err := s.PaymentChannelOpenInstruction(intents.OpenPayload{Mode: intents.SessionModePush}); err == nil {
		t.Fatalf("expected open instruction error on missing fields")
	}
}

func TestVerifyVoucherUnknownChannelAndBadCumulative(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	session, _, _ := seededSession(9)
	v, _ := session.PrepareIncrement(10)
	if _, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v}); err == nil {
		t.Fatalf("expected unknown channel error")
	}
	bad := v
	bad.Data.Cumulative = "notanumber"
	if _, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: bad}); err == nil {
		t.Fatalf("expected bad cumulative error")
	}
}

func TestVerifyVoucherRejectsFinalizedAndClosed(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(11)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))

	// Finalized rejects.
	if err := s.MarkFinalized(ctx, channelID); err != nil {
		t.Fatal(err)
	}
	v, _ := session.PrepareIncrement(50)
	if _, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v}); err == nil {
		t.Fatalf("expected finalized rejection")
	}

	// Close-pending rejects.
	session2, signer2, channelID2 := seededSession(12)
	_, _ = s.ProcessOpen(ctx, openPush(channelID2, 1_000, signer2))
	if _, err := s.ProcessClose(ctx, intents.ClosePayload{ChannelID: channelID2}); err != nil {
		t.Fatal(err)
	}
	v2, _ := session2.PrepareIncrement(50)
	if _, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v2}); err == nil {
		t.Fatalf("expected close-pending rejection")
	}
}

func TestVerifyVoucherInvalidSignatureOnReplay(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(13)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	v, _ := session.SignIncrement(100)
	if _, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v}); err != nil {
		t.Fatal(err)
	}
	// Replay path with same cumulative/signature but corrupt the stored signer so
	// signature verification on replay fails.
	st, _, _ := s.Store().GetChannel(ctx, channelID)
	st.AuthorizedSigner = solana.NewWallet().PublicKey().String()
	_ = s.Store().PutChannel(ctx, channelID, st)
	if _, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v}); err == nil {
		t.Fatalf("expected signature verification failure on replay")
	}
}

func TestProcessTopUpErrors(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	_, signer, channelID := seededSession(14)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))

	if _, err := s.ProcessTopUp(ctx, intents.TopUpPayload{ChannelID: channelID, NewDeposit: "bad"}); err == nil {
		t.Fatalf("expected invalid newDeposit error")
	}
	if _, err := s.ProcessTopUp(ctx, intents.TopUpPayload{ChannelID: "ghost", NewDeposit: "2000"}); err == nil {
		t.Fatalf("expected missing channel error")
	}
	if _, err := s.ProcessTopUp(ctx, intents.TopUpPayload{ChannelID: channelID, NewDeposit: "99999999"}); err == nil {
		t.Fatalf("expected over-cap error")
	}
}

func TestBeginDeliveryErrorsAndDefaults(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	_, signer, channelID := seededSession(15)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))

	if _, err := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 0}); err == nil {
		t.Fatalf("expected zero amount error")
	}
	if _, err := s.BeginDelivery(ctx, DeliveryRequest{SessionID: "ghost", Amount: 10}); err == nil {
		t.Fatalf("expected missing channel error")
	}
	// Explicit expiry and deliveryId, then duplicate id rejection.
	exp := time.Now().Add(time.Hour).Unix()
	d, err := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 10, DeliveryID: "dup", ExpiresAt: &exp, CommitURL: "http://c", Proof: "p"})
	if err != nil {
		t.Fatal(err)
	}
	if d.ExpiresAt != exp || d.CommitURL != "http://c" || d.Proof != "p" {
		t.Fatalf("directive fields mismatch: %+v", d)
	}
	if _, err := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 10, DeliveryID: "dup"}); err == nil {
		t.Fatalf("expected duplicate pending delivery rejection")
	}
}

func TestBeginDeliveryRejectsAfterCloseAndFinalize(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	_, signer, channelID := seededSession(16)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	_, _ = s.ProcessClose(ctx, intents.ClosePayload{ChannelID: channelID})
	if _, err := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 10}); err == nil {
		t.Fatalf("expected close-pending delivery rejection")
	}

	_, signer2, channelID2 := seededSession(17)
	_, _ = s.ProcessOpen(ctx, openPush(channelID2, 1_000, signer2))
	_ = s.MarkFinalized(ctx, channelID2)
	if _, err := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID2, Amount: 10}); err == nil {
		t.Fatalf("expected finalized delivery rejection")
	}
}

func TestProcessCommitErrors(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(18)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))

	// Bad cumulative.
	bad := intents.CommitPayload{DeliveryID: "x", Voucher: intents.SignedVoucher{Data: intents.VoucherData{ChannelID: channelID, Cumulative: "bad"}}}
	if _, err := s.ProcessCommit(ctx, bad); err == nil {
		t.Fatalf("expected bad cumulative error")
	}

	// Unknown channel.
	v, _ := session.PrepareIncrement(50)
	ghost := intents.CommitPayload{DeliveryID: "x", Voucher: v}
	ghost.Voucher.Data.ChannelID = solana.NewWallet().PublicKey().String()
	if _, err := s.ProcessCommit(ctx, ghost); err == nil {
		t.Fatalf("expected unknown channel error")
	}

	// Delivery not reserved.
	notReserved, _ := session.SignIncrement(50)
	if _, err := s.ProcessCommit(ctx, intents.CommitPayload{DeliveryID: "missing", Voucher: notReserved}); err == nil {
		t.Fatalf("expected delivery-not-found error")
	}
}

func TestProcessCommitExpiredDelivery(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(19)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	past := time.Now().Add(-time.Hour).Unix()
	d, err := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 50, DeliveryID: "exp", ExpiresAt: &past})
	if err != nil {
		t.Fatal(err)
	}
	v, _ := session.SignIncrement(50)
	if _, err := s.ProcessCommit(ctx, intents.CommitPayload{DeliveryID: d.DeliveryID, Voucher: v}); err == nil {
		t.Fatalf("expected expired delivery rejection")
	}
}

func TestProcessCommitConflictingVoucher(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(20)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	d, _ := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 100, DeliveryID: "c1"})
	v, _ := session.SignIncrement(100)
	if _, err := s.ProcessCommit(ctx, intents.CommitPayload{DeliveryID: d.DeliveryID, Voucher: v}); err != nil {
		t.Fatal(err)
	}
	// Same deliveryId, different voucher -> conflict.
	other, _ := session.SignIncrement(50)
	if _, err := s.ProcessCommit(ctx, intents.CommitPayload{DeliveryID: d.DeliveryID, Voucher: other}); err == nil {
		t.Fatalf("expected conflicting voucher rejection")
	}
}

func TestProcessCloseErrorsAndFinalVoucher(t *testing.T) {
	s := makeServer()
	ctx := context.Background()

	// Missing channel.
	if _, err := s.ProcessClose(ctx, intents.ClosePayload{ChannelID: "ghost"}); err == nil {
		t.Fatalf("expected missing channel error")
	}

	// Final voucher exceeding deposit.
	session, signer, channelID := seededSession(21)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 200, signer))
	over, _ := session.PrepareIncrement(500)
	if _, err := s.ProcessClose(ctx, intents.ClosePayload{ChannelID: channelID, Voucher: &over}); err == nil {
		t.Fatalf("expected over-deposit final voucher rejection")
	}

	// Double close rejects.
	session2, signer2, channelID2 := seededSession(22)
	_, _ = s.ProcessOpen(ctx, openPush(channelID2, 1_000, signer2))
	if _, err := s.ProcessClose(ctx, intents.ClosePayload{ChannelID: channelID2}); err != nil {
		t.Fatal(err)
	}
	_ = session2
	if _, err := s.ProcessClose(ctx, intents.ClosePayload{ChannelID: channelID2}); err == nil {
		t.Fatalf("expected double-close rejection")
	}

	// Final voucher equal to watermark with matching signature (idempotent path).
	session3, signer3, channelID3 := seededSession(23)
	_, _ = s.ProcessOpen(ctx, openPush(channelID3, 1_000, signer3))
	v3, _ := session3.SignIncrement(100)
	if _, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v3}); err != nil {
		t.Fatal(err)
	}
	params, err := s.ProcessClose(ctx, intents.ClosePayload{ChannelID: channelID3, Voucher: &v3})
	if err != nil {
		t.Fatal(err)
	}
	if params.Settled != 100 {
		t.Fatalf("settled = %d, want 100", params.Settled)
	}
}

func TestProcessCloseInvalidCumulative(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	_, signer, channelID := seededSession(24)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	v := intents.SignedVoucher{Data: intents.VoucherData{ChannelID: channelID, Cumulative: "bad", ExpiresAt: intents.DefaultSessionExpiresAt}}
	if _, err := s.ProcessClose(ctx, intents.ClosePayload{ChannelID: channelID, Voucher: &v}); err == nil {
		t.Fatalf("expected invalid cumulative error")
	}
}

func TestFinalizeParamsErrorsAndSplits(t *testing.T) {
	ctx := context.Background()

	// Missing channel.
	s := makeServer()
	if _, err := s.FinalizeParams(ctx, "ghost"); err == nil {
		t.Fatalf("expected missing channel error")
	}

	// Splits and operator populate FinalizeParams.
	split := solana.NewWallet().PublicKey()
	s2 := NewSessionServer(SessionConfig{
		Operator: testRecipient, Recipient: testRecipient, MaxCap: 10_000_000,
		Currency: "USDC", Network: "localnet",
		Splits: []SessionSplit{{Recipient: split, Bps: 1000}},
	}, nil)
	session, signer, channelID := seededSession(25)
	_, _ = s2.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	v, _ := session.SignIncrement(300)
	if _, err := s2.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v}); err != nil {
		t.Fatal(err)
	}
	params, err := s2.FinalizeParams(ctx, channelID)
	if err != nil {
		t.Fatal(err)
	}
	if params.Settled != 300 || len(params.Splits) != 1 {
		t.Fatalf("finalize params mismatch: %+v", params)
	}
	if params.AuthorizedSigner == nil {
		t.Fatalf("authorized signer should be set")
	}
	if params.Mint == nil {
		t.Fatalf("mint should be resolved")
	}
}

func TestProgramIDOverrideAndDefault(t *testing.T) {
	def := makeServer()
	if def.programID().IsZero() {
		t.Fatalf("default program id should be non-zero")
	}
	override := solana.NewWallet().PublicKey()
	s := NewSessionServer(SessionConfig{
		Operator: testRecipient, Recipient: testRecipient,
		Currency: "USDC", Network: "localnet", ProgramID: override.String(),
	}, nil)
	if !s.programID().Equals(override) {
		t.Fatalf("override program id mismatch")
	}
	// Invalid override falls back to default.
	bad := NewSessionServer(SessionConfig{
		Operator: testRecipient, Recipient: testRecipient,
		Currency: "USDC", Network: "localnet", ProgramID: "!!!",
	}, nil)
	if bad.programID().IsZero() {
		t.Fatalf("invalid override should fall back to default")
	}
}

func TestExpectedMintUnknownCurrency(t *testing.T) {
	s := NewSessionServer(SessionConfig{
		Operator: testRecipient, Recipient: testRecipient,
		Currency: "DOESNOTEXIST", Network: "localnet",
	}, nil)
	if _, err := s.expectedMint(); err == nil {
		t.Fatalf("expected unresolved mint error")
	}
}

func TestParsePayloadPubkeyErrors(t *testing.T) {
	if _, err := parsePayloadPubkey("", "payer"); err == nil {
		t.Fatalf("expected missing field error")
	}
	if _, err := parsePayloadPubkey("!!!", "payer"); err == nil {
		t.Fatalf("expected invalid pubkey error")
	}
}

func TestVerifyVoucherSignatureErrors(t *testing.T) {
	// Expired.
	expired := intents.SignedVoucher{Data: intents.VoucherData{ExpiresAt: time.Now().Add(-time.Hour).Unix()}}
	if err := verifyVoucherSignature(expired, testRecipient); err == nil {
		t.Fatalf("expected expired voucher error")
	}
	// Invalid channel in MessageBytes.
	badMsg := intents.SignedVoucher{Data: intents.VoucherData{ChannelID: "!!!", Cumulative: "1", ExpiresAt: intents.DefaultSessionExpiresAt}}
	if err := verifyVoucherSignature(badMsg, testRecipient); err == nil {
		t.Fatalf("expected message bytes error")
	}
	// Invalid signature encoding.
	session, _, channelID := seededSession(26)
	v, _ := session.PrepareIncrement(10)
	v.Signature = "!!!notbase58"
	v.Data.ChannelID = channelID
	if err := verifyVoucherSignature(v, testRecipient); err == nil {
		t.Fatalf("expected invalid signature encoding error")
	}
	// Invalid authorized signer.
	good, _ := session.PrepareIncrement(10)
	if err := verifyVoucherSignature(good, "!!!"); err == nil {
		t.Fatalf("expected invalid authorizedSigner error")
	}
	// Signature mismatch against valid but wrong signer.
	wrongSigner := solana.NewWallet().PublicKey().String()
	if err := verifyVoucherSignature(good, wrongSigner); err == nil {
		t.Fatalf("expected signature verification failure")
	}
}

func TestVerifyVoucherSuccessAdvancesWatermark(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(30)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	v1, _ := session.SignIncrement(100)
	if cum, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v1}); err != nil || cum != 100 {
		t.Fatalf("first advance mismatch: cum=%d err=%v", cum, err)
	}
	v2, _ := session.SignIncrement(150)
	if cum, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v2}); err != nil || cum != 250 {
		t.Fatalf("second advance mismatch: cum=%d err=%v", cum, err)
	}
	// A stale lower voucher is rejected against the advanced watermark.
	stale, _ := mppclient.NewActiveSession(mustPubkey(t, channelID), seededSignerKey(30)).PrepareIncrement(50)
	if _, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: stale}); err == nil {
		t.Fatalf("expected stale voucher rejection")
	}
}

func TestProcessCommitPartialAmountAndOverReserved(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(31)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))

	// Reserve 200 but commit only 120: partial commit is accepted.
	d, _ := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 200, DeliveryID: "p1"})
	v, _ := session.SignIncrement(120)
	receipt, err := s.ProcessCommit(ctx, intents.CommitPayload{DeliveryID: d.DeliveryID, Voucher: v})
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Amount != "120" || receipt.Status != intents.CommitStatusCommitted {
		t.Fatalf("partial commit mismatch: %+v", receipt)
	}

	// Reserve 50 but commit a voucher claiming +500: exceeds reserved amount.
	d2, _ := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 50, DeliveryID: "p2"})
	over, _ := session.SignIncrement(500)
	if _, err := s.ProcessCommit(ctx, intents.CommitPayload{DeliveryID: d2.DeliveryID, Voucher: over}); err == nil {
		t.Fatalf("expected over-reserved commit rejection")
	}
}

func TestProcessCommitNonIncreasingCumulative(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(32)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	// Advance watermark to 100 via a committed delivery.
	d, _ := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 100, DeliveryID: "a"})
	v, _ := session.SignIncrement(100)
	if _, err := s.ProcessCommit(ctx, intents.CommitPayload{DeliveryID: d.DeliveryID, Voucher: v}); err != nil {
		t.Fatal(err)
	}
	// New delivery but voucher cumulative equals the current watermark. Sign it
	// with the session key so the signature check passes and the non-increasing
	// branch inside the update closure is reached.
	d2, _ := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 100, DeliveryID: "b"})
	flat, err := signVoucherFor(channelID, 32, 100)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.ProcessCommit(ctx, intents.CommitPayload{DeliveryID: d2.DeliveryID, Voucher: flat}); err == nil {
		t.Fatalf("expected non-increasing commit rejection")
	}
}

func TestProcessCommitBadSignature(t *testing.T) {
	s := makeServer()
	ctx := context.Background()
	_, signer, channelID := seededSession(33)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	d, _ := s.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 100, DeliveryID: "x"})
	// Wrong-signer voucher fails signature verification before reservation lookup.
	wrong, _ := mppclient.NewActiveSession(mustPubkey(t, channelID), seededSignerKey(99)).SignIncrement(50)
	if _, err := s.ProcessCommit(ctx, intents.CommitPayload{DeliveryID: d.DeliveryID, Voucher: wrong}); err == nil {
		t.Fatalf("expected commit signature rejection")
	}
}

func TestFinalizeParamsWithoutOperator(t *testing.T) {
	ctx := context.Background()
	s := makeServer()
	session, signer, channelID := seededSession(34)
	open := openPush(channelID, 1_000, signer)
	open.Owner = ""
	open.Payer = ""
	_, _ = s.ProcessOpen(ctx, open)
	v, _ := session.SignIncrement(80)
	if _, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v}); err != nil {
		t.Fatal(err)
	}
	params, err := s.FinalizeParams(ctx, channelID)
	if err != nil {
		t.Fatal(err)
	}
	if params.Payer != nil {
		t.Fatalf("payer should be nil when operator is empty")
	}
	if params.Settled != 80 {
		t.Fatalf("settled = %d, want 80", params.Settled)
	}
}

func TestProcessCloseWithStrictlyHigherFinalVoucher(t *testing.T) {
	ctx := context.Background()
	s := makeServer()
	session, signer, channelID := seededSession(35)
	_, _ = s.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	// First advance the watermark, then close with a strictly higher final voucher.
	v1, _ := session.SignIncrement(100)
	if _, err := s.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v1}); err != nil {
		t.Fatal(err)
	}
	final, _ := session.SignIncrement(200) // cumulative 300
	params, err := s.ProcessClose(ctx, intents.ClosePayload{ChannelID: channelID, Voucher: &final})
	if err != nil {
		t.Fatal(err)
	}
	if params.Settled != 300 {
		t.Fatalf("settled = %d, want 300", params.Settled)
	}
}

// signVoucherFor signs an absolute-cumulative voucher with a deterministic seed
// keyed session for the given channel, used to exercise server-side branches.
func signVoucherFor(channelID string, seed byte, cumulative uint64) (intents.SignedVoucher, error) {
	pub, err := solana.PublicKeyFromBase58(channelID)
	if err != nil {
		return intents.SignedVoucher{}, err
	}
	return mppclient.NewActiveSession(pub, seededSignerKey(seed)).PrepareVoucher(cumulative)
}

var _ = mppclient.NewActiveSession
