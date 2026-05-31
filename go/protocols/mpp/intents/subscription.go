package intents

import (
	"fmt"
	"math/big"
)

// SubscriptionPeriodUnit is the billing period unit. The Solana profile
// supports "day" and "week" only; "month" is rejected because the on-chain
// program uses fixed elapsed seconds and cannot represent calendar-month
// cadence exactly. Wire form mirrors rust/src/protocol/intents/subscription.rs.
type SubscriptionPeriodUnit string

const (
	// PeriodUnitDay is a one-day billing cadence (24 hours).
	PeriodUnitDay SubscriptionPeriodUnit = "day"
	// PeriodUnitWeek is a one-week billing cadence (168 hours).
	PeriodUnitWeek SubscriptionPeriodUnit = "week"
)

// ToPeriodHours maps a (unit, count) pair to the subscriptions program's
// period_hours value. Returns an error if the count is out of range for the
// unit or if the resulting period_hours exceeds the program's [1, 8760] bound.
func (u SubscriptionPeriodUnit) ToPeriodHours(periodCount uint64) (uint64, error) {
	if periodCount == 0 {
		return 0, fmt.Errorf("periodCount must be a positive integer")
	}
	switch u {
	case PeriodUnitDay:
		if periodCount > 365 {
			return 0, fmt.Errorf("periodCount=%d for periodUnit=\"day\" exceeds 365", periodCount)
		}
		return periodCount * 24, nil
	case PeriodUnitWeek:
		if periodCount > 52 {
			return 0, fmt.Errorf("periodCount=%d for periodUnit=\"week\" exceeds 52", periodCount)
		}
		return periodCount * 168, nil
	default:
		return 0, fmt.Errorf("unsupported periodUnit %q (Solana profile supports \"day\" and \"week\")", string(u))
	}
}

// SubscriptionRequest is the subscription intent body for the Solana
// subscription intent. Amounts are string-encoded base units; period_count is
// a decimal string. Wire field casing mirrors the Rust SubscriptionRequest.
type SubscriptionRequest struct {
	// Amount is the per-period token amount in base units.
	Amount string `json:"amount"`
	// Currency is the base58 SPL token mint (canonical wire form).
	Currency string `json:"currency"`
	// PeriodUnit is the billing period unit ("day" or "week").
	PeriodUnit SubscriptionPeriodUnit `json:"periodUnit"`
	// PeriodCount is the decimal string count of period_unit values per billing period.
	PeriodCount string `json:"periodCount"`
	// Recipient is the primary recipient wallet pubkey (base58).
	Recipient string `json:"recipient"`
	// SubscriptionExpires is the optional RFC3339 expiry of the recurring authorization.
	SubscriptionExpires string `json:"subscriptionExpires,omitempty"`
	// Description is a human-readable description.
	Description string `json:"description,omitempty"`
	// ExternalID is a merchant reference.
	ExternalID string `json:"externalId,omitempty"`
	// MethodDetails carries Solana-specific extension fields.
	MethodDetails any `json:"methodDetails,omitempty"`
}

// ParsePeriodCount parses PeriodCount as an unsigned integer.
func (r SubscriptionRequest) ParsePeriodCount() (uint64, error) {
	return parseUint64Decimal(r.PeriodCount, "periodCount")
}

// ParseAmount parses Amount as an unsigned integer.
func (r SubscriptionRequest) ParseAmount() (uint64, error) {
	return parseUint64Decimal(r.Amount, "amount")
}

// PeriodHours computes the on-chain period_hours for this request, validating
// both the period mapping and the program-level bound [1, 8760].
func (r SubscriptionRequest) PeriodHours() (uint64, error) {
	count, err := r.ParsePeriodCount()
	if err != nil {
		return 0, err
	}
	hours, err := r.PeriodUnit.ToPeriodHours(count)
	if err != nil {
		return 0, err
	}
	if hours == 0 || hours > 8760 {
		return 0, fmt.Errorf("period_hours %d out of [1, 8760] range", hours)
	}
	return hours, nil
}

func parseUint64Decimal(value, field string) (uint64, error) {
	parsed := new(big.Int)
	if _, ok := parsed.SetString(value, 10); !ok || parsed.Sign() < 0 || !parsed.IsUint64() {
		return 0, fmt.Errorf("invalid %s: %s", field, value)
	}
	return parsed.Uint64(), nil
}
