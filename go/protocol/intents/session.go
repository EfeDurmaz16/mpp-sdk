package intents

import (
	"encoding/json"
	"fmt"
	"math/big"
)

// DefaultSessionExpiresAt is the shared default voucher/directive expiry.
const DefaultSessionExpiresAt int64 = 4102444800

// SessionMode is the on-chain funding mechanism for a session.
type SessionMode string

const (
	SessionModePush SessionMode = "push"
	SessionModePull SessionMode = "pull"
)

// SessionPullVoucherStrategy is the voucher authority used for pull sessions.
type SessionPullVoucherStrategy string

const (
	SessionPullVoucherStrategyClientVoucher   SessionPullVoucherStrategy = "clientVoucher"
	SessionPullVoucherStrategyOperatedVoucher SessionPullVoucherStrategy = "operatedVoucher"
)

// SessionSplit is a basis-point split distributed when a session settles.
type SessionSplit struct {
	Recipient string `json:"recipient"`
	BPS       uint16 `json:"bps"`
}

// Validate checks the split fields.
func (s SessionSplit) Validate() error {
	if s.Recipient == "" {
		return fmt.Errorf("split recipient is required")
	}
	if s.BPS == 0 || s.BPS > 10000 {
		return fmt.Errorf("split bps must be between 1 and 10000")
	}
	return nil
}

// SessionRequest is the request embedded in a Solana session challenge.
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

// Validate checks the shared session request fields.
func (r SessionRequest) Validate() error {
	if err := requirePositiveBaseUnits(r.Cap, "cap"); err != nil {
		return err
	}
	if r.Currency == "" {
		return fmt.Errorf("currency is required")
	}
	if r.Operator == "" {
		return fmt.Errorf("operator is required")
	}
	if r.Recipient == "" {
		return fmt.Errorf("recipient is required")
	}
	for _, split := range r.Splits {
		if err := split.Validate(); err != nil {
			return err
		}
	}
	if r.MinVoucherDelta != "" {
		if err := requirePositiveBaseUnits(r.MinVoucherDelta, "minVoucherDelta"); err != nil {
			return err
		}
	}
	if hasPullMode(r.Modes) && r.PullVoucherStrategy == nil {
		return fmt.Errorf("pullVoucherStrategy is required when pull mode is advertised")
	}
	return nil
}

// OpenPayload is the client open action payload for push or pull sessions.
type OpenPayload struct {
	Action              string      `json:"action"`
	Mode                SessionMode `json:"mode"`
	ChannelID           string      `json:"channelId,omitempty"`
	Deposit             string      `json:"deposit,omitempty"`
	Payer               string      `json:"payer,omitempty"`
	Payee               string      `json:"payee,omitempty"`
	Mint                string      `json:"mint,omitempty"`
	Salt                string      `json:"salt,omitempty"`
	GracePeriod         *uint32     `json:"gracePeriod,omitempty"`
	Transaction         string      `json:"transaction,omitempty"`
	TokenAccount        string      `json:"tokenAccount,omitempty"`
	ApprovedAmount      string      `json:"approvedAmount,omitempty"`
	Owner               string      `json:"owner,omitempty"`
	InitMultiDelegateTx string      `json:"initMultiDelegateTx,omitempty"`
	UpdateDelegationTx  string      `json:"updateDelegationTx,omitempty"`
	AuthorizedSigner    string      `json:"authorizedSigner"`
	Signature           string      `json:"signature"`
}

// Validate checks the mode-specific open fields.
func (p OpenPayload) Validate() error {
	if p.Action != "open" {
		return fmt.Errorf("action must be open")
	}
	if p.AuthorizedSigner == "" {
		return fmt.Errorf("authorizedSigner is required")
	}
	if p.Signature == "" {
		return fmt.Errorf("signature is required")
	}
	switch p.Mode {
	case SessionModePush:
		if p.ChannelID == "" {
			return fmt.Errorf("channelId is required for push open")
		}
		return requirePositiveBaseUnits(p.Deposit, "deposit")
	case SessionModePull:
		if p.TokenAccount == "" && p.ChannelID == "" {
			return fmt.Errorf("tokenAccount or channelId is required for pull open")
		}
		if p.ApprovedAmount != "" {
			return requirePositiveBaseUnits(p.ApprovedAmount, "approvedAmount")
		}
		return nil
	default:
		return fmt.Errorf("unsupported session mode: %s", p.Mode)
	}
}

// VoucherData is the canonical signed voucher content.
type VoucherData struct {
	ChannelID        string  `json:"channelId"`
	CumulativeAmount string  `json:"cumulativeAmount"`
	ExpiresAt        int64   `json:"expiresAt"`
	Nonce            *uint64 `json:"nonce,omitempty"`
}

// UnmarshalJSON accepts both cumulativeAmount and the Rust alias cumulative.
func (v *VoucherData) UnmarshalJSON(data []byte) error {
	type voucherData VoucherData
	var raw struct {
		voucherData
		Cumulative string `json:"cumulative"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*v = VoucherData(raw.voucherData)
	if v.CumulativeAmount == "" {
		v.CumulativeAmount = raw.Cumulative
	}
	return nil
}

// Validate checks the voucher fields.
func (v VoucherData) Validate() error {
	if v.ChannelID == "" {
		return fmt.Errorf("channelId is required")
	}
	if err := requirePositiveBaseUnits(v.CumulativeAmount, "cumulativeAmount"); err != nil {
		return err
	}
	if v.ExpiresAt <= 0 {
		return fmt.Errorf("expiresAt must be positive")
	}
	return nil
}

// SignedVoucher is a signed cumulative voucher.
type SignedVoucher struct {
	Data      VoucherData `json:"data"`
	Signature string      `json:"signature"`
}

// Validate checks the signed voucher fields.
func (v SignedVoucher) Validate() error {
	if err := v.Data.Validate(); err != nil {
		return err
	}
	if v.Signature == "" {
		return fmt.Errorf("signature is required")
	}
	return nil
}

// MeteringDirective is a server-issued directive attached to delivered work.
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

// Validate checks the directive fields.
func (d MeteringDirective) Validate() error {
	if d.DeliveryID == "" {
		return fmt.Errorf("deliveryId is required")
	}
	if d.SessionID == "" {
		return fmt.Errorf("sessionId is required")
	}
	if err := requirePositiveBaseUnits(d.Amount, "amount"); err != nil {
		return err
	}
	if d.Currency == "" {
		return fmt.Errorf("currency is required")
	}
	if d.ExpiresAt <= 0 {
		return fmt.Errorf("expiresAt must be positive")
	}
	return nil
}

// CommitReceipt is returned after a delivery commit is accepted.
type CommitReceipt struct {
	DeliveryID string       `json:"deliveryId"`
	SessionID  string       `json:"sessionId"`
	Amount     string       `json:"amount"`
	Cumulative string       `json:"cumulative"`
	Status     CommitStatus `json:"status"`
}

// CommitStatus is a commit receipt status.
type CommitStatus string

const (
	CommitStatusCommitted CommitStatus = "committed"
	CommitStatusReplayed  CommitStatus = "replayed"
)

// Validate checks the receipt fields.
func (r CommitReceipt) Validate() error {
	if r.DeliveryID == "" {
		return fmt.Errorf("deliveryId is required")
	}
	if r.SessionID == "" {
		return fmt.Errorf("sessionId is required")
	}
	if err := requirePositiveBaseUnits(r.Amount, "amount"); err != nil {
		return err
	}
	if err := requirePositiveBaseUnits(r.Cumulative, "cumulative"); err != nil {
		return err
	}
	if r.Status != CommitStatusCommitted && r.Status != CommitStatusReplayed {
		return fmt.Errorf("status must be committed or replayed")
	}
	return nil
}

func hasPullMode(modes []SessionMode) bool {
	for _, mode := range modes {
		if mode == SessionModePull {
			return true
		}
	}
	return false
}

func requirePositiveBaseUnits(value string, fieldName string) error {
	parsed := new(big.Int)
	if _, ok := parsed.SetString(value, 10); !ok || parsed.Sign() <= 0 {
		return fmt.Errorf("%s must be a positive base-unit integer string", fieldName)
	}
	return nil
}
