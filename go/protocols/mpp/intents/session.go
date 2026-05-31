package intents

import (
	"encoding/json"
	"fmt"
	"strconv"

	solana "github.com/gagliardetto/solana-go"

	"github.com/solana-foundation/pay-kit/go/protocols/mpp/program"
)

// DefaultSessionExpiresAt is the default session voucher/directive expiry:
// 2100-01-01T00:00:00Z. It stays below JavaScript's max safe integer so JSON
// intermediaries do not round it before the credential is decoded. Mirrors
// DEFAULT_SESSION_EXPIRES_AT in the Rust spine.
const DefaultSessionExpiresAt int64 = 4_102_444_800

// SessionMode is the on-chain funding mechanism for a session.
type SessionMode string

const (
	// SessionModePush is a payment channel backed by an on-chain escrow
	// deposit (client-funded).
	SessionModePush SessionMode = "push"
	// SessionModePull is an operator-assisted session whose voucher authority
	// is declared separately via SessionPullVoucherStrategy.
	SessionModePull SessionMode = "pull"
)

// SessionPullVoucherStrategy is the voucher authority used when pull mode is
// advertised.
type SessionPullVoucherStrategy string

const (
	// PullStrategyClientVoucher means the client signs cumulative vouchers.
	PullStrategyClientVoucher SessionPullVoucherStrategy = "clientVoucher"
	// PullStrategyOperatedVoucher means the operator signs vouchers.
	PullStrategyOperatedVoucher SessionPullVoucherStrategy = "operatedVoucher"
)

// SessionSplit is a payment split committed at channel open; distributed to a
// specific recipient when the channel closes.
type SessionSplit struct {
	Recipient string `json:"recipient"`
	Bps       uint16 `json:"bps"`
}

// SessionRequest is the session intent request embedded in a 402 challenge.
// Field casing and omit rules mirror SessionRequest in the Rust spine.
type SessionRequest struct {
	Cap                 string                      `json:"cap"`
	Currency            string                      `json:"currency"`
	Decimals            *uint8                      `json:"decimals,omitempty"`
	Network             string                      `json:"network,omitempty"`
	Operator            string                      `json:"operator"`
	Recipient           string                      `json:"recipient"`
	Splits              []SessionSplit              `json:"splits,omitempty"`
	ProgramID           string                      `json:"programId,omitempty"`
	Description         string                      `json:"description,omitempty"`
	ExternalID          string                      `json:"externalId,omitempty"`
	MinVoucherDelta     string                      `json:"minVoucherDelta,omitempty"`
	Modes               []SessionMode               `json:"modes,omitempty"`
	PullVoucherStrategy *SessionPullVoucherStrategy `json:"pullVoucherStrategy,omitempty"`
	RecentBlockhash     string                      `json:"recentBlockhash,omitempty"`
}

// OpenPayload is the payload for the open action. Shape varies by mode; use
// the constructors to build it and Mode to distinguish variants on the server.
type OpenPayload struct {
	Mode SessionMode `json:"mode"`

	// Push mode.
	ChannelID   string  `json:"channelId,omitempty"`
	Deposit     string  `json:"deposit,omitempty"`
	Payer       string  `json:"payer,omitempty"`
	Payee       string  `json:"payee,omitempty"`
	Mint        string  `json:"mint,omitempty"`
	Salt        *uint64 `json:"-"`
	GracePeriod *uint32 `json:"gracePeriod,omitempty"`
	Transaction string  `json:"transaction,omitempty"`

	// Pull mode.
	TokenAccount        string `json:"tokenAccount,omitempty"`
	ApprovedAmount      string `json:"approvedAmount,omitempty"`
	Owner               string `json:"owner,omitempty"`
	InitMultiDelegateTx string `json:"initMultiDelegateTx,omitempty"`
	UpdateDelegationTx  string `json:"updateDelegationTx,omitempty"`

	// Shared.
	AuthorizedSigner string `json:"authorizedSigner"`
	Signature        string `json:"signature"`
}

// openPayloadWire is the JSON projection of OpenPayload with salt serialized
// as a decimal string (number-tolerant on read). JSON numbers > 2^53 are
// unsafe in JS intermediaries, so salt is always emitted as a string.
type openPayloadWire struct {
	Mode                SessionMode      `json:"mode"`
	ChannelID           string           `json:"channelId,omitempty"`
	Deposit             string           `json:"deposit,omitempty"`
	Payer               string           `json:"payer,omitempty"`
	Payee               string           `json:"payee,omitempty"`
	Mint                string           `json:"mint,omitempty"`
	Salt                *string          `json:"salt,omitempty"`
	GracePeriod         *uint32          `json:"gracePeriod,omitempty"`
	Transaction         string           `json:"transaction,omitempty"`
	TokenAccount        string           `json:"tokenAccount,omitempty"`
	ApprovedAmount      string           `json:"approvedAmount,omitempty"`
	Owner               string           `json:"owner,omitempty"`
	InitMultiDelegateTx string           `json:"initMultiDelegateTx,omitempty"`
	UpdateDelegationTx  string           `json:"updateDelegationTx,omitempty"`
	AuthorizedSigner    string           `json:"authorizedSigner"`
	Signature           string           `json:"signature"`
	SaltRaw             *json.RawMessage `json:"-"`
}

// MarshalJSON emits salt as a decimal string and omits empty/None fields.
func (p OpenPayload) MarshalJSON() ([]byte, error) {
	w := openPayloadWire{
		Mode:                p.Mode,
		ChannelID:           p.ChannelID,
		Deposit:             p.Deposit,
		Payer:               p.Payer,
		Payee:               p.Payee,
		Mint:                p.Mint,
		GracePeriod:         p.GracePeriod,
		Transaction:         p.Transaction,
		TokenAccount:        p.TokenAccount,
		ApprovedAmount:      p.ApprovedAmount,
		Owner:               p.Owner,
		InitMultiDelegateTx: p.InitMultiDelegateTx,
		UpdateDelegationTx:  p.UpdateDelegationTx,
		AuthorizedSigner:    p.AuthorizedSigner,
		Signature:           p.Signature,
	}
	if p.Salt != nil {
		s := strconv.FormatUint(*p.Salt, 10)
		w.Salt = &s
	}
	return json.Marshal(w)
}

// UnmarshalJSON reads salt from either a decimal string or a JSON number.
func (p *OpenPayload) UnmarshalJSON(data []byte) error {
	var w struct {
		openPayloadWire
		Salt json.RawMessage `json:"salt"`
	}
	if err := json.Unmarshal(data, &w); err != nil {
		return err
	}
	p.Mode = w.Mode
	p.ChannelID = w.ChannelID
	p.Deposit = w.Deposit
	p.Payer = w.Payer
	p.Payee = w.Payee
	p.Mint = w.Mint
	p.GracePeriod = w.GracePeriod
	p.Transaction = w.Transaction
	p.TokenAccount = w.TokenAccount
	p.ApprovedAmount = w.ApprovedAmount
	p.Owner = w.Owner
	p.InitMultiDelegateTx = w.InitMultiDelegateTx
	p.UpdateDelegationTx = w.UpdateDelegationTx
	p.AuthorizedSigner = w.AuthorizedSigner
	p.Signature = w.Signature
	salt, err := parseOptionalU64(w.Salt)
	if err != nil {
		return err
	}
	p.Salt = salt
	return nil
}

// parseOptionalU64 accepts a decimal string, a JSON number, or null.
func parseOptionalU64(raw json.RawMessage) (*uint64, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	if raw[0] == '"' {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return nil, err
		}
		value, err := strconv.ParseUint(s, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("salt must be a decimal string: %w", err)
		}
		return &value, nil
	}
	value, err := strconv.ParseUint(string(raw), 10, 64)
	if err != nil {
		return nil, fmt.Errorf("salt must be an unsigned 64-bit integer: %w", err)
	}
	return &value, nil
}

// NewOpenPush builds a push payment-channel open payload.
func NewOpenPush(channelID, deposit, authorizedSigner, signature string) OpenPayload {
	return OpenPayload{
		Mode:             SessionModePush,
		ChannelID:        channelID,
		Deposit:          deposit,
		AuthorizedSigner: authorizedSigner,
		Signature:        signature,
	}
}

// NewOpenPaymentChannel builds a push payment-channel open payload carrying the
// full channel parameters.
func NewOpenPaymentChannel(
	channelID, deposit, payer, payee, mint string,
	salt uint64, gracePeriod uint32,
	authorizedSigner, signature string,
) OpenPayload {
	return NewOpenPaymentChannelWithMode(SessionModePush, channelID, deposit, payer, payee, mint, salt, gracePeriod, authorizedSigner, signature)
}

// NewOpenPaymentChannelWithMode builds a payment-channel open payload with an
// explicit submission mode (push: client broadcasts; pull: operator broadcasts).
func NewOpenPaymentChannelWithMode(
	mode SessionMode,
	channelID, deposit, payer, payee, mint string,
	salt uint64, gracePeriod uint32,
	authorizedSigner, signature string,
) OpenPayload {
	saltCopy := salt
	graceCopy := gracePeriod
	return OpenPayload{
		Mode:             mode,
		ChannelID:        channelID,
		Deposit:          deposit,
		Payer:            payer,
		Payee:            payee,
		Mint:             mint,
		Salt:             &saltCopy,
		GracePeriod:      &graceCopy,
		AuthorizedSigner: authorizedSigner,
		Signature:        signature,
	}
}

// NewOpenPull builds a pull (SPL delegation) open payload.
func NewOpenPull(tokenAccount, approvedAmount, owner, authorizedSigner, signature string) OpenPayload {
	return OpenPayload{
		Mode:             SessionModePull,
		TokenAccount:     tokenAccount,
		ApprovedAmount:   approvedAmount,
		Owner:            owner,
		AuthorizedSigner: authorizedSigner,
		Signature:        signature,
	}
}

// SessionID returns the session store key: channelId for push, tokenAccount
// for pull-without-channel.
func (p OpenPayload) SessionID() (string, error) {
	if p.ChannelID != "" {
		return p.ChannelID, nil
	}
	switch p.Mode {
	case SessionModePush:
		return "", fmt.Errorf("push open missing channelId")
	case SessionModePull:
		if p.TokenAccount == "" {
			return "", fmt.Errorf("pull open missing channelId or tokenAccount")
		}
		return p.TokenAccount, nil
	default:
		return "", fmt.Errorf("unknown session mode %q", p.Mode)
	}
}

// DepositAmount returns the deposit (push) or approved amount (pull) in base units.
func (p OpenPayload) DepositAmount() (uint64, error) {
	raw := p.Deposit
	if raw == "" {
		switch p.Mode {
		case SessionModePush:
			return 0, fmt.Errorf("push open missing deposit")
		case SessionModePull:
			if p.ApprovedAmount == "" {
				return 0, fmt.Errorf("pull open missing deposit or approvedAmount")
			}
			raw = p.ApprovedAmount
		default:
			return 0, fmt.Errorf("unknown session mode %q", p.Mode)
		}
	}
	value, err := strconv.ParseUint(raw, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid deposit amount: %s", raw)
	}
	return value, nil
}

// VoucherData is the canonical content of a voucher signed by the client's
// session key. The wire JSON carries channelId (base58), cumulativeAmount
// (string; also accepts the legacy "cumulative" alias on read), and expiresAt
// (i64). The signed bytes are the program Borsh VoucherArgs layout.
type VoucherData struct {
	ChannelID  string
	Cumulative string
	ExpiresAt  int64
	Nonce      *uint64
}

type voucherDataWire struct {
	ChannelID        string  `json:"channelId"`
	CumulativeAmount string  `json:"cumulativeAmount"`
	Cumulative       string  `json:"cumulative,omitempty"`
	ExpiresAt        int64   `json:"expiresAt"`
	Nonce            *uint64 `json:"nonce,omitempty"`
}

// MarshalJSON serializes cumulative only as cumulativeAmount.
func (v VoucherData) MarshalJSON() ([]byte, error) {
	return json.Marshal(voucherDataWire{
		ChannelID:        v.ChannelID,
		CumulativeAmount: v.Cumulative,
		ExpiresAt:        v.ExpiresAt,
		Nonce:            v.Nonce,
	})
}

// UnmarshalJSON accepts both cumulativeAmount and the legacy cumulative alias.
func (v *VoucherData) UnmarshalJSON(data []byte) error {
	var w voucherDataWire
	if err := json.Unmarshal(data, &w); err != nil {
		return err
	}
	v.ChannelID = w.ChannelID
	v.Cumulative = w.CumulativeAmount
	if v.Cumulative == "" {
		v.Cumulative = w.Cumulative
	}
	v.ExpiresAt = w.ExpiresAt
	v.Nonce = w.Nonce
	return nil
}

// MessageBytes serializes the voucher to the payment-channels VoucherArgs bytes
// signed by Ed25519: channelId(32) || cumulative(u64 LE) || expiresAt(i64 LE).
func (v VoucherData) MessageBytes() ([]byte, error) {
	channelID, err := solana.PublicKeyFromBase58(v.ChannelID)
	if err != nil {
		return nil, fmt.Errorf("invalid voucher channelId: %w", err)
	}
	cumulative, err := strconv.ParseUint(v.Cumulative, 10, 64)
	if err != nil {
		return nil, fmt.Errorf("invalid voucher cumulative: %s", v.Cumulative)
	}
	return program.VoucherMessageBytes(channelID, cumulative, v.ExpiresAt), nil
}

// SignedVoucher is a voucher signed by the client's session key. Vouchers are
// cumulative: the server always uses the latest valid voucher it received.
type SignedVoucher struct {
	Data      VoucherData `json:"data"`
	Signature string      `json:"signature"`
}

// VoucherPayload is the payload for the voucher action.
type VoucherPayload struct {
	Voucher SignedVoucher `json:"voucher"`
}

// CommitPayload is the payload for the commit action.
type CommitPayload struct {
	DeliveryID string        `json:"deliveryId"`
	Voucher    SignedVoucher `json:"voucher"`
}

// TopUpPayload is the payload for the topup action.
type TopUpPayload struct {
	ChannelID  string `json:"channelId"`
	NewDeposit string `json:"newDeposit"`
	Signature  string `json:"signature"`
}

// ClosePayload is the payload for the close action.
type ClosePayload struct {
	ChannelID string         `json:"channelId"`
	Voucher   *SignedVoucher `json:"voucher,omitempty"`
}

// SessionActionTag identifies the action variant.
type SessionActionTag string

const (
	// ActionOpen opens a new channel/delegation and starts the session.
	ActionOpen SessionActionTag = "open"
	// ActionVoucher submits a signed voucher authorizing payment.
	ActionVoucher SessionActionTag = "voucher"
	// ActionCommit commits a metered delivery by attaching a signed voucher.
	ActionCommit SessionActionTag = "commit"
	// ActionTopUp tops up an existing channel's deposit. The wire tag uses a
	// capital U ("topUp") to match the Rust serde camelCase rename.
	ActionTopUp SessionActionTag = "topUp"
	// ActionClose requests cooperative close of the channel.
	ActionClose SessionActionTag = "close"
)

// SessionAction is the tagged action submitted by the client in an
// Authorization header, discriminated by the "action" field. Exactly one of
// the payload pointers is set, matching the active tag.
type SessionAction struct {
	Action  SessionActionTag
	Open    *OpenPayload
	Voucher *VoucherPayload
	Commit  *CommitPayload
	TopUp   *TopUpPayload
	Close   *ClosePayload
}

// MarshalJSON flattens the active payload alongside the action tag.
func (a SessionAction) MarshalJSON() ([]byte, error) {
	var payload any
	switch a.Action {
	case ActionOpen:
		payload = a.Open
	case ActionVoucher:
		payload = a.Voucher
	case ActionCommit:
		payload = a.Commit
	case ActionTopUp:
		payload = a.TopUp
	case ActionClose:
		payload = a.Close
	default:
		return nil, fmt.Errorf("unknown session action %q", a.Action)
	}
	if payload == nil {
		return nil, fmt.Errorf("session action %q has no payload", a.Action)
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return nil, err
	}
	tag, err := json.Marshal(string(a.Action))
	if err != nil {
		return nil, err
	}
	fields["action"] = tag
	return json.Marshal(fields)
}

// UnmarshalJSON reads the action tag then decodes the matching payload.
func (a *SessionAction) UnmarshalJSON(data []byte) error {
	var tag struct {
		Action SessionActionTag `json:"action"`
	}
	if err := json.Unmarshal(data, &tag); err != nil {
		return err
	}
	a.Action = tag.Action
	switch tag.Action {
	case ActionOpen:
		var p OpenPayload
		if err := json.Unmarshal(data, &p); err != nil {
			return err
		}
		a.Open = &p
	case ActionVoucher:
		var p VoucherPayload
		if err := json.Unmarshal(data, &p); err != nil {
			return err
		}
		a.Voucher = &p
	case ActionCommit:
		var p CommitPayload
		if err := json.Unmarshal(data, &p); err != nil {
			return err
		}
		a.Commit = &p
	case ActionTopUp:
		var p TopUpPayload
		if err := json.Unmarshal(data, &p); err != nil {
			return err
		}
		a.TopUp = &p
	case ActionClose:
		var p ClosePayload
		if err := json.Unmarshal(data, &p); err != nil {
			return err
		}
		a.Close = &p
	default:
		return fmt.Errorf("unknown session action %q", tag.Action)
	}
	return nil
}

// MeteringDirective is the server-issued directive attached to a delivered
// message/response. After processing, the client signs a voucher covering
// amount and commits it referencing deliveryId.
type MeteringDirective struct {
	DeliveryID string `json:"deliveryId"`
	SessionID  string `json:"sessionId"`
	Amount     string `json:"amount"`
	Currency   string `json:"currency"`
	Sequence   uint64 `json:"sequence"`
	ExpiresAt  int64  `json:"expiresAt"`
	CommitURL  string `json:"commitUrl,omitempty"`
	Proof      string `json:"proof,omitempty"`
}

// AmountBaseUnits parses the directive amount as base units.
func (d MeteringDirective) AmountBaseUnits() (uint64, error) {
	value, err := strconv.ParseUint(d.Amount, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid metering amount: %s", d.Amount)
	}
	return value, nil
}

// MeteringUsage is the final usage reported by a streaming response. The amount
// must be less than or equal to the amount reserved by the directive.
type MeteringUsage struct {
	DeliveryID string `json:"deliveryId"`
	Amount     string `json:"amount"`
}

// AmountBaseUnits parses the usage amount as base units.
func (u MeteringUsage) AmountBaseUnits() (uint64, error) {
	value, err := strconv.ParseUint(u.Amount, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid metering usage amount: %s", u.Amount)
	}
	return value, nil
}

// MeteredEnvelope pairs a payload with the metering directive needed to
// acknowledge it.
type MeteredEnvelope[T any] struct {
	Payload  T                 `json:"payload"`
	Metering MeteringDirective `json:"metering"`
}

// CommitStatus is the commit receipt status.
type CommitStatus string

const (
	// CommitStatusCommitted is the first successful commit for a delivery.
	CommitStatusCommitted CommitStatus = "committed"
	// CommitStatusReplayed is an idempotent replay of a prior accepted commit.
	CommitStatusReplayed CommitStatus = "replayed"
)

// CommitReceipt is returned after a delivery commit is accepted.
type CommitReceipt struct {
	DeliveryID string       `json:"deliveryId"`
	SessionID  string       `json:"sessionId"`
	Amount     string       `json:"amount"`
	Cumulative string       `json:"cumulative"`
	Status     CommitStatus `json:"status"`
}
