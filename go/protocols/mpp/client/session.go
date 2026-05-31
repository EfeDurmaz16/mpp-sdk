package client

import (
	"fmt"
	"strconv"

	solana "github.com/gagliardetto/solana-go"

	"github.com/solana-foundation/pay-kit/go/paycore/solanatx"
	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
)

// DefaultVoucherExpiresAt is the default voucher expiry: 2100-01-01T00:00:00Z.
// It stays below JavaScript's max safe integer so JSON intermediaries do not
// round it before the credential is decoded.
const DefaultVoucherExpiresAt int64 = intents.DefaultSessionExpiresAt

// ActiveSession tracks the client-side state of an active payment session. It
// holds a session signing key and advances the cumulative watermark with each
// signed voucher. Vouchers are Ed25519-signed over the on-chain Borsh voucher
// layout used by the payment-channels program. Mirrors ActiveSession in the
// Rust spine (client/session.rs).
type ActiveSession struct {
	channelID  solana.PublicKey
	cumulative uint64
	nonce      uint64
	expiresAt  int64
	signer     solanatx.Signer
}

// NewActiveSession creates a session tracker. channelID is the on-chain channel
// address obtained after opening; the signer's public key becomes the
// authorizedSigner in the open action.
func NewActiveSession(channelID solana.PublicKey, signer solanatx.Signer) *ActiveSession {
	return &ActiveSession{
		channelID: channelID,
		expiresAt: DefaultVoucherExpiresAt,
		signer:    signer,
	}
}

// NewActiveSessionWithExpiry creates a session tracker with an explicit voucher
// expiry.
func NewActiveSessionWithExpiry(channelID solana.PublicKey, signer solanatx.Signer, expiresAt int64) *ActiveSession {
	s := NewActiveSession(channelID, signer)
	s.expiresAt = expiresAt
	return s
}

// Cumulative returns the current settled watermark known to the client.
func (s *ActiveSession) Cumulative() uint64 { return s.cumulative }

// SetExpiresAt updates the expiry used for subsequent vouchers.
func (s *ActiveSession) SetExpiresAt(expiresAt int64) { s.expiresAt = expiresAt }

// AuthorizedSigner returns the session signer public key (base58).
func (s *ActiveSession) AuthorizedSigner() string { return s.signer.PublicKey().String() }

// ChannelIDStr returns the channel id as base58.
func (s *ActiveSession) ChannelIDStr() string { return s.channelID.String() }

// PrepareVoucher prepares a signed voucher with an absolute cumulative amount
// without advancing the local watermark. cumulative MUST exceed the current
// watermark.
func (s *ActiveSession) PrepareVoucher(cumulative uint64) (intents.SignedVoucher, error) {
	if cumulative <= s.cumulative {
		return intents.SignedVoucher{}, fmt.Errorf("voucher cumulative %d must exceed current watermark %d", cumulative, s.cumulative)
	}
	nonce := s.nonce + 1
	data := intents.VoucherData{
		ChannelID:  s.ChannelIDStr(),
		Cumulative: strconv.FormatUint(cumulative, 10),
		ExpiresAt:  s.expiresAt,
		Nonce:      &nonce,
	}
	message, err := data.MessageBytes()
	if err != nil {
		return intents.SignedVoucher{}, err
	}
	signature, err := s.signer.Sign(message)
	if err != nil {
		return intents.SignedVoucher{}, fmt.Errorf("signing failed: %w", err)
	}
	return intents.SignedVoucher{Data: data, Signature: signature.String()}, nil
}

// PrepareIncrement prepares a signed voucher adding amount without advancing
// the local watermark.
func (s *ActiveSession) PrepareIncrement(amount uint64) (intents.SignedVoucher, error) {
	return s.PrepareVoucher(s.cumulative + amount)
}

// RecordVoucher advances the local watermark after a voucher is accepted.
func (s *ActiveSession) RecordVoucher(voucher intents.SignedVoucher) error {
	cumulative, err := strconv.ParseUint(voucher.Data.Cumulative, 10, 64)
	if err != nil {
		return fmt.Errorf("invalid voucher cumulative")
	}
	if cumulative <= s.cumulative {
		return fmt.Errorf("voucher cumulative %d must exceed current watermark %d", cumulative, s.cumulative)
	}
	s.cumulative = cumulative
	next := s.nonce + 1
	if voucher.Data.Nonce != nil && *voucher.Data.Nonce > next {
		next = *voucher.Data.Nonce
	}
	s.nonce = next
	return nil
}

// SignVoucher signs and records a voucher with an absolute cumulative amount.
func (s *ActiveSession) SignVoucher(cumulative uint64) (intents.SignedVoucher, error) {
	voucher, err := s.PrepareVoucher(cumulative)
	if err != nil {
		return intents.SignedVoucher{}, err
	}
	if err := s.RecordVoucher(voucher); err != nil {
		return intents.SignedVoucher{}, err
	}
	return voucher, nil
}

// SignIncrement signs and records a voucher adding amount to the watermark.
func (s *ActiveSession) SignIncrement(amount uint64) (intents.SignedVoucher, error) {
	return s.SignVoucher(s.cumulative + amount)
}

// VoucherAction builds a voucher action wrapping a freshly-signed increment.
func (s *ActiveSession) VoucherAction(amount uint64) (intents.SessionAction, error) {
	voucher, err := s.SignIncrement(amount)
	if err != nil {
		return intents.SessionAction{}, err
	}
	return intents.SessionAction{
		Action:  intents.ActionVoucher,
		Voucher: &intents.VoucherPayload{Voucher: voucher},
	}, nil
}

// OpenAction builds an open action for push mode after the on-chain open
// transaction is confirmed.
func (s *ActiveSession) OpenAction(deposit uint64, openTxSignature string) intents.SessionAction {
	payload := intents.NewOpenPush(s.ChannelIDStr(), strconv.FormatUint(deposit, 10), s.AuthorizedSigner(), openTxSignature)
	return intents.SessionAction{Action: intents.ActionOpen, Open: &payload}
}

// OpenPaymentChannelAction builds a push payment-channel open action.
func (s *ActiveSession) OpenPaymentChannelAction(
	deposit uint64, payer, payee, mint string, salt uint64, gracePeriod uint32, openTxSignature string,
) intents.SessionAction {
	return s.OpenPaymentChannelActionWithMode(intents.SessionModePush, deposit, payer, payee, mint, salt, gracePeriod, openTxSignature)
}

// OpenPaymentChannelActionWithMode builds a payment-channel open action with an
// explicit submission mode.
func (s *ActiveSession) OpenPaymentChannelActionWithMode(
	mode intents.SessionMode, deposit uint64, payer, payee, mint string, salt uint64, gracePeriod uint32, openTxSignature string,
) intents.SessionAction {
	payload := intents.NewOpenPaymentChannelWithMode(
		mode, s.ChannelIDStr(), strconv.FormatUint(deposit, 10), payer, payee, mint, salt, gracePeriod, s.AuthorizedSigner(), openTxSignature)
	return intents.SessionAction{Action: intents.ActionOpen, Open: &payload}
}

// OpenPullAction builds an open action for pull mode (SPL token delegation).
// The session channel id is used as the delegated token account.
func (s *ActiveSession) OpenPullAction(approvedAmount uint64, owner, approveTxSignature string) intents.SessionAction {
	payload := intents.NewOpenPull(s.ChannelIDStr(), strconv.FormatUint(approvedAmount, 10), owner, s.AuthorizedSigner(), approveTxSignature)
	return intents.SessionAction{Action: intents.ActionOpen, Open: &payload}
}

// TopUpAction builds a topup action after a top-up transaction.
func (s *ActiveSession) TopUpAction(newDeposit uint64, topupTxSignature string) intents.SessionAction {
	return intents.SessionAction{
		Action: intents.ActionTopUp,
		TopUp: &intents.TopUpPayload{
			ChannelID:  s.ChannelIDStr(),
			NewDeposit: strconv.FormatUint(newDeposit, 10),
			Signature:  topupTxSignature,
		},
	}
}

// CloseAction builds a close action for cooperative channel close. When
// finalIncrement is non-nil and greater than zero, a final voucher for the
// remaining balance is signed before closing.
func (s *ActiveSession) CloseAction(finalIncrement *uint64) (intents.SessionAction, error) {
	close := &intents.ClosePayload{ChannelID: s.ChannelIDStr()}
	if finalIncrement != nil && *finalIncrement > 0 {
		voucher, err := s.SignIncrement(*finalIncrement)
		if err != nil {
			return intents.SessionAction{}, err
		}
		close.Voucher = &voucher
	}
	return intents.SessionAction{Action: intents.ActionClose, Close: close}, nil
}
