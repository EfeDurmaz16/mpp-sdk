package server

import (
	"context"
	"crypto/ed25519"
	"testing"

	solana "github.com/gagliardetto/solana-go"

	mppclient "github.com/solana-foundation/pay-kit/go/protocols/mpp/client"
	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
	"github.com/solana-foundation/pay-kit/go/protocols/mpp/program"
)

const testRecipient = "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY"

func makeServer() *SessionServer {
	return NewSessionServer(SessionConfig{
		Operator:  testRecipient,
		Recipient: testRecipient,
		MaxCap:    10_000_000,
		Currency:  "USDC",
		Decimals:  6,
		Network:   "localnet",
	}, nil)
}

func seededSession(seed byte) (*mppclient.ActiveSession, string, string) {
	b := make([]byte, 32)
	for i := range b {
		b[i] = seed
	}
	priv := solana.PrivateKey(ed25519.NewKeyFromSeed(b))
	channel := solana.NewWallet().PublicKey()
	session := mppclient.NewActiveSession(channel, priv)
	return session, session.AuthorizedSigner(), channel.String()
}

func openPush(channelID string, deposit uint64, signer string) intents.OpenPayload {
	return intents.NewOpenPush(channelID, itoa(deposit), signer, "dummy_tx_sig")
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

func TestBuildChallengeRequestClampsCap(t *testing.T) {
	server := makeServer()
	req := server.BuildChallengeRequest(50_000_000)
	if req.Cap != "10000000" {
		t.Fatalf("cap = %s, want clamped 10000000", req.Cap)
	}
	if len(req.Modes) != 0 {
		t.Fatalf("push-only server should omit modes, got %v", req.Modes)
	}
}

func TestProcessOpenStoresState(t *testing.T) {
	server := makeServer()
	state, err := server.ProcessOpen(context.Background(), openPush("chan1", 1_000_000, "signer1"))
	if err != nil {
		t.Fatal(err)
	}
	if state.Deposit != 1_000_000 || state.Cumulative != 0 || state.Finalized {
		t.Fatalf("state mismatch: %+v", state)
	}
}

func TestProcessOpenRejectsZeroAndOverCap(t *testing.T) {
	server := makeServer()
	if _, err := server.ProcessOpen(context.Background(), openPush("chan1", 0, "s")); err == nil {
		t.Fatalf("expected zero deposit rejection")
	}
	if _, err := server.ProcessOpen(context.Background(), openPush("chan1", 20_000_000, "s")); err == nil {
		t.Fatalf("expected over-cap rejection")
	}
}

func TestProcessOpenRejectsUnadvertisedPull(t *testing.T) {
	server := makeServer()
	payload := intents.NewOpenPaymentChannelWithMode(intents.SessionModePull, "chan1", "1000000", "payer", testRecipient, "mint", 1, 900, "signer1", "pending")
	if _, err := server.ProcessOpen(context.Background(), payload); err == nil {
		t.Fatalf("expected unadvertised pull mode rejection")
	}
}

func TestVerifyVoucherAdvancesAndReplays(t *testing.T) {
	server := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(42)
	if _, err := server.ProcessOpen(ctx, openPush(channelID, 1_000, signer)); err != nil {
		t.Fatal(err)
	}
	voucher, err := session.PrepareIncrement(250)
	if err != nil {
		t.Fatal(err)
	}
	cumulative, err := server.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: voucher})
	if err != nil {
		t.Fatal(err)
	}
	if cumulative != 250 {
		t.Fatalf("cumulative = %d, want 250", cumulative)
	}
	// Idempotent replay of the exact same voucher returns the same watermark.
	replay, err := server.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: voucher})
	if err != nil {
		t.Fatalf("replay should succeed: %v", err)
	}
	if replay != 250 {
		t.Fatalf("replay cumulative = %d, want 250", replay)
	}
}

func TestVerifyVoucherRejectsNonIncreasingAndOverDeposit(t *testing.T) {
	server := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(42)
	_, _ = server.ProcessOpen(ctx, openPush(channelID, 300, signer))
	v, _ := session.SignIncrement(250)
	if _, err := server.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v}); err != nil {
		t.Fatal(err)
	}
	// A fresh voucher exceeding deposit is rejected.
	session2, signer2, channelID2 := seededSession(7)
	_, _ = server.ProcessOpen(ctx, openPush(channelID2, 100, signer2))
	over, _ := session2.PrepareIncrement(500)
	if _, err := server.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: over}); err == nil {
		t.Fatalf("expected over-deposit rejection")
	}
}

func TestVerifyVoucherEnforcesMinDelta(t *testing.T) {
	server := NewSessionServer(SessionConfig{
		Operator: testRecipient, Recipient: testRecipient, MaxCap: 10_000_000,
		Currency: "USDC", Decimals: 6, Network: "localnet", MinVoucherDelta: 100,
	}, nil)
	ctx := context.Background()
	session, signer, channelID := seededSession(42)
	_, _ = server.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	small, _ := session.PrepareIncrement(50)
	if _, err := server.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: small}); err == nil {
		t.Fatalf("expected below-min-delta rejection")
	}
}

func TestMeteredDeliveryCommitAndReplay(t *testing.T) {
	server := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(42)
	_, _ = server.ProcessOpen(ctx, openPush(channelID, 1_000, signer))

	directive, err := server.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 125})
	if err != nil {
		t.Fatal(err)
	}
	if directive.Sequence != 1 || directive.Amount != "125" {
		t.Fatalf("directive mismatch: %+v", directive)
	}
	voucher, _ := session.SignIncrement(125)
	payload := intents.CommitPayload{DeliveryID: directive.DeliveryID, Voucher: voucher}
	receipt, err := server.ProcessCommit(ctx, payload)
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Status != intents.CommitStatusCommitted || receipt.Amount != "125" || receipt.Cumulative != "125" {
		t.Fatalf("commit receipt mismatch: %+v", receipt)
	}
	// Duplicate deliveryId returns a replayed receipt, not a re-settlement.
	replay, err := server.ProcessCommit(ctx, payload)
	if err != nil {
		t.Fatal(err)
	}
	if replay.Status != intents.CommitStatusReplayed {
		t.Fatalf("expected replayed status, got %s", replay.Status)
	}
}

func TestBeginDeliveryRejectsOverDeposit(t *testing.T) {
	server := makeServer()
	ctx := context.Background()
	_, signer, channelID := seededSession(42)
	_, _ = server.ProcessOpen(ctx, openPush(channelID, 100, signer))
	if _, err := server.BeginDelivery(ctx, DeliveryRequest{SessionID: channelID, Amount: 200}); err == nil {
		t.Fatalf("expected over-deposit delivery rejection")
	}
}

func TestProcessTopUpRaisesDeposit(t *testing.T) {
	server := makeServer()
	ctx := context.Background()
	_, signer, channelID := seededSession(42)
	_, _ = server.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	state, err := server.ProcessTopUp(ctx, intents.TopUpPayload{ChannelID: channelID, NewDeposit: "5000", Signature: "tx"})
	if err != nil {
		t.Fatal(err)
	}
	if state.Deposit != 5000 {
		t.Fatalf("deposit = %d, want 5000", state.Deposit)
	}
	if _, err := server.ProcessTopUp(ctx, intents.TopUpPayload{ChannelID: channelID, NewDeposit: "1000"}); err == nil {
		t.Fatalf("expected lower-deposit rejection")
	}
}

func TestProcessCloseSetsPendingAndReturnsFinalize(t *testing.T) {
	server := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(42)
	_, _ = server.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	final, _ := session.PrepareIncrement(200)
	params, err := server.ProcessClose(ctx, intents.ClosePayload{ChannelID: channelID, Voucher: &final})
	if err != nil {
		t.Fatal(err)
	}
	if params.Settled != 200 {
		t.Fatalf("settled = %d, want 200", params.Settled)
	}
	// No further vouchers accepted after close.
	v, _ := session.PrepareIncrement(300)
	if _, err := server.VerifyVoucher(ctx, intents.VoucherPayload{Voucher: v}); err == nil {
		t.Fatalf("expected close-pending rejection")
	}
}

func TestPaymentChannelOpenParamsValidatesChallenge(t *testing.T) {
	server := NewSessionServer(SessionConfig{
		Operator: testRecipient, Recipient: testRecipient, MaxCap: 10_000_000,
		Currency: "USDC", Decimals: 6, Network: "mainnet-beta",
		Modes:               []intents.SessionMode{intents.SessionModePull},
		PullVoucherStrategy: ptrStrategy(intents.PullStrategyClientVoucher),
	}, nil)
	payer := solana.NewWallet().PublicKey()
	authorizedSigner := solana.NewWallet().PublicKey()
	mint := server.mustMint(t)
	channel, _, err := program.FindChannelPDA(payer, mustPubkey(t, testRecipient), mint, authorizedSigner, 77, program.DefaultProgramID())
	if err != nil {
		t.Fatal(err)
	}
	payload := intents.NewOpenPaymentChannelWithMode(
		intents.SessionModePull, channel.String(), "1000000",
		payer.String(), testRecipient, mint.String(), 77, 900, authorizedSigner.String(), "pending")
	params, err := server.PaymentChannelOpenParams(payload)
	if err != nil {
		t.Fatal(err)
	}
	if !params.Payer.Equals(payer) || !params.Mint.Equals(mint) {
		t.Fatalf("params mismatch")
	}
	// Wrong payee is rejected.
	wrong := payload
	wrong.Payee = solana.NewWallet().PublicKey().String()
	if _, err := server.PaymentChannelOpenParams(wrong); err == nil {
		t.Fatalf("expected payee mismatch rejection")
	}
}

func TestPaymentChannelOpenInstructionAndStore(t *testing.T) {
	server := NewSessionServer(SessionConfig{
		Operator: testRecipient, Recipient: testRecipient, MaxCap: 10_000_000,
		Currency: "USDC", Decimals: 6, Network: "mainnet-beta",
		Modes:               []intents.SessionMode{intents.SessionModePull},
		PullVoucherStrategy: ptrStrategy(intents.PullStrategyClientVoucher),
	}, nil)
	if server.Store() == nil {
		t.Fatalf("store getter returned nil")
	}
	payer := solana.NewWallet().PublicKey()
	authorizedSigner := solana.NewWallet().PublicKey()
	mint := server.mustMint(t)
	channel, _, err := program.FindChannelPDA(payer, mustPubkey(t, testRecipient), mint, authorizedSigner, 77, program.DefaultProgramID())
	if err != nil {
		t.Fatal(err)
	}
	payload := intents.NewOpenPaymentChannelWithMode(
		intents.SessionModePull, channel.String(), "1000000",
		payer.String(), testRecipient, mint.String(), 77, 900, authorizedSigner.String(), "pending")
	ix, err := server.PaymentChannelOpenInstruction(payload)
	if err != nil {
		t.Fatal(err)
	}
	if !ix.ProgramID().Equals(program.DefaultProgramID()) {
		t.Fatalf("open instruction program id mismatch")
	}
}

func TestMarkFinalized(t *testing.T) {
	server := makeServer()
	ctx := context.Background()
	_, signer, channelID := seededSession(42)
	_, _ = server.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	if err := server.MarkFinalized(ctx, channelID); err != nil {
		t.Fatal(err)
	}
	state, _, _ := server.Store().GetChannel(ctx, channelID)
	if !state.Finalized {
		t.Fatalf("channel should be finalized")
	}
	if err := server.MarkFinalized(ctx, "ghost"); err == nil {
		t.Fatalf("expected error finalizing missing channel")
	}
}

func TestVoucherActionRoundtripThroughServer(t *testing.T) {
	server := makeServer()
	ctx := context.Background()
	session, signer, channelID := seededSession(7)
	_, _ = server.ProcessOpen(ctx, openPush(channelID, 1_000, signer))
	action, err := session.VoucherAction(100)
	if err != nil {
		t.Fatal(err)
	}
	cumulative, err := server.VerifyVoucher(ctx, *action.Voucher)
	if err != nil {
		t.Fatal(err)
	}
	if cumulative != 100 {
		t.Fatalf("cumulative = %d, want 100", cumulative)
	}
}

func ptrStrategy(s intents.SessionPullVoucherStrategy) *intents.SessionPullVoucherStrategy { return &s }

func mustPubkey(t *testing.T, s string) solana.PublicKey {
	t.Helper()
	pk, err := solana.PublicKeyFromBase58(s)
	if err != nil {
		t.Fatal(err)
	}
	return pk
}

func (s *SessionServer) mustMint(t *testing.T) solana.PublicKey {
	t.Helper()
	mint, err := s.expectedMint()
	if err != nil {
		t.Fatal(err)
	}
	return mint
}
