package paycore

import (
	"encoding/json"
	"fmt"
)

// SubscriptionMethodDetails is the typed methodDetails payload for the Solana
// subscription intent. The server (which builds and HMAC-pins it into the 402
// challenge) and the client (which reads it back to construct the activation
// transaction) both use this struct directly.
//
// The expected_* and plan_* server-extension fields mirror the immutable Plan
// terms the on-chain Subscribe instruction needs in its SubscribeData payload.
// Including them in the challenge lets the client build a settle-able
// activation transaction without an extra RPC roundtrip to fetch the Plan
// account. When absent the client falls back to RPC. Wire casing mirrors
// rust/src/protocol/intents/subscription.rs.
type SubscriptionMethodDetails struct {
	// PlanID is the base58 of the on-chain Plan PDA (the spec's externalId).
	PlanID string `json:"planId"`
	// Mint is the base58 SPL token mint. MUST equal the on-chain plan.mint.
	Mint string `json:"mint"`
	// TokenProgram is the base58 SPL Token / Token-2022 program id used for the
	// per-period transfers.
	TokenProgram string `json:"tokenProgram"`
	// Decimals is the decimal precision of the mint. Server-populated.
	Decimals *uint8 `json:"decimals,omitempty"`
	// Puller is the base58 of the server's puller pubkey. MUST be plan.owner or
	// appear in plan.pullers.
	Puller string `json:"puller"`
	// Merchant is the base58 of the Plan's owner (the merchant who published
	// it). The on-chain Subscribe instruction needs this as its second account
	// meta and as part of the Plan PDA derivation. When unset, the client falls
	// back to Puller.
	Merchant string `json:"merchant,omitempty"`
	// Recipient is the base58 of the recipient wallet — must be in
	// plan.destinations (or the whitelist must be empty).
	Recipient string `json:"recipient,omitempty"`
	// Amount is the per-period charge amount in base units (decimal string).
	// Mirrors SubscriptionRequest.Amount.
	Amount string `json:"amount,omitempty"`
	// ProgramID is the subscriptions program ID. Omit for the canonical mainnet
	// deployment.
	ProgramID string `json:"programId,omitempty"`
	// Network is the Solana network slug — mainnet, mainnet-beta, devnet,
	// testnet, localnet.
	Network string `json:"network,omitempty"`
	// FeePayer, when true, means the server pays activation transaction fees.
	FeePayer bool `json:"feePayer,omitempty"`
	// FeePayerKey is the base58 fee-payer pubkey. REQUIRED when FeePayer is true.
	FeePayerKey string `json:"feePayerKey,omitempty"`
	// RecentBlockhash is a pre-fetched recent blockhash. When set, the client
	// skips its own getLatestBlockhash RPC call.
	RecentBlockhash string `json:"recentBlockhash,omitempty"`
	// PlanIDNumeric is the on-chain plan_id (u64) the program reads from
	// SubscribeData. PlanID above is the PDA derived from this number.
	PlanIDNumeric *uint64 `json:"planIdNumeric,omitempty"`
	// PlanBump is the Plan PDA's bump seed.
	PlanBump *uint8 `json:"planBump,omitempty"`
	// ExpectedPeriodHours is the Plan's period_hours.
	ExpectedPeriodHours *uint64 `json:"expectedPeriodHours,omitempty"`
	// ExpectedCreatedAt is the Plan's created_at unix timestamp.
	ExpectedCreatedAt *int64 `json:"expectedCreatedAt,omitempty"`
}

// SubscriptionMethodDetailsFromValue decodes a parsed methodDetails JSON value
// into a SubscriptionMethodDetails.
func SubscriptionMethodDetailsFromValue(value any) (SubscriptionMethodDetails, error) {
	if value == nil {
		return SubscriptionMethodDetails{}, nil
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return SubscriptionMethodDetails{}, fmt.Errorf("invalid methodDetails: %w", err)
	}
	var details SubscriptionMethodDetails
	if err := json.Unmarshal(raw, &details); err != nil {
		return SubscriptionMethodDetails{}, fmt.Errorf("invalid methodDetails: %w", err)
	}
	return details, nil
}

// Validate checks the spec's REQUIRED fields are non-empty. The struct can be
// decoded with missing required fields, so callers that need a settle-able
// activation must run this check.
func (d SubscriptionMethodDetails) Validate() error {
	if d.PlanID == "" {
		return fmt.Errorf("methodDetails.planId is required")
	}
	if d.Mint == "" {
		return fmt.Errorf("methodDetails.mint is required")
	}
	if d.TokenProgram == "" {
		return fmt.Errorf("methodDetails.tokenProgram is required")
	}
	if d.Puller == "" {
		return fmt.Errorf("methodDetails.puller is required")
	}
	if d.FeePayer && d.FeePayerKey == "" {
		return fmt.Errorf("methodDetails.feePayerKey is required when feePayer is true")
	}
	return nil
}

// ActivatePayload is the activation credential payload. It mirrors the Solana
// charge profile's two-mode shape: type="transaction" (server broadcasts) or
// type="signature" (client already broadcast).
type ActivatePayload struct {
	// Type is the payload type discriminator: "transaction" or "signature".
	Type string `json:"type"`
	// Transaction is the standard base64 of the serialized activation
	// transaction (when type="transaction").
	Transaction string `json:"transaction,omitempty"`
	// Signature is the base58 of the on-chain transaction signature (when
	// type="signature").
	Signature string `json:"signature,omitempty"`
}

// SubscriptionAction is the tagged single-action credential wrapper. The Solana
// subscription profile only defines "activate"; renewals are server-driven and
// cancellations are out-of-band on-chain.
type SubscriptionAction struct {
	// Action is the tag, always "activate" for the Solana profile.
	Action string `json:"action"`
	// Type mirrors ActivatePayload.Type when flattened into the tagged shape.
	Type string `json:"type,omitempty"`
	// Transaction mirrors ActivatePayload.Transaction.
	Transaction string `json:"transaction,omitempty"`
	// Signature mirrors ActivatePayload.Signature.
	Signature string `json:"signature,omitempty"`
}

// SubscriptionReceiptExtensions are the extension fields placed on the standard
// Receipt's metadata for a subscription activation or renewal.
type SubscriptionReceiptExtensions struct {
	// SubscriptionID is the base58 of the on-chain SubscriptionDelegation PDA.
	SubscriptionID string `json:"subscriptionId"`
	// PlanID is the base58 of the on-chain Plan PDA.
	PlanID string `json:"planId"`
	// PeriodIndex is the decimal index of the billing period (0 for activation).
	PeriodIndex string `json:"periodIndex"`
	// PeriodStartTs is the RFC3339 timestamp of the current period's start.
	PeriodStartTs string `json:"periodStartTs"`
	// PeriodEndTs is the RFC3339 timestamp of the current period's end (exclusive).
	PeriodEndTs string `json:"periodEndTs"`
	// ExpiresAt is the RFC3339 effective subscription expiry, when set.
	ExpiresAt string `json:"expiresAt,omitempty"`
	// ActivationSignature is the base58 of the activation transaction signature.
	ActivationSignature string `json:"activationSignature,omitempty"`
}
