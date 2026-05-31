// Package subscriptions carries the typed helpers for the on-chain
// subscriptions program: hand-written PDA derivations, program-ID
// constants, single-byte instruction discriminators, instruction data
// structs with little-endian no-padding ToBytes encoders, and
// solana.Instruction builders.
//
// The byte layouts and account orders mirror rust/crates/mpp/src/program/
// subscriptions.rs exactly so the cross-language interop harness exercises
// byte-identical instruction data. On-chain structs use #[repr(C, packed)]
// with no padding; the ToBytes methods emit the matching wire form.
//
// This module is dependency-light by design (no Codama-generated client):
// v0 of the Go SDK does not bind to a generated crate. A follow-up should
// adopt the Codama client and re-export it.
package subscriptions

import (
	"encoding/binary"
	"fmt"

	solana "github.com/gagliardetto/solana-go"
)

// SubscriptionsProgramID is the canonical mainnet program ID for the
// subscriptions program.
const SubscriptionsProgramID = "De1egAFMkMWZSN5rYXRj9CAdheBamobVNubTsi9avR44"

// PDA seed prefixes. These mirror the on-chain program's seed constants.
var (
	// SubscriptionAuthoritySeed is the PDA seed for the SubscriptionAuthority account.
	SubscriptionAuthoritySeed = []byte("SubscriptionAuthority")
	// SubscriptionDelegationSeed is the PDA seed for the SubscriptionDelegation account.
	SubscriptionDelegationSeed = []byte("subscription")
	// PlanSeed is the PDA seed for the Plan account.
	PlanSeed = []byte("plan")
	// EventAuthoritySeed is the PDA seed for the event_authority account. The
	// subscriptions program emits events via self-CPI from a PDA derived with
	// this seed.
	EventAuthoritySeed = []byte("event_authority")
)

// Well-known program IDs used by the subscription instruction builders.
const (
	AssociatedTokenProgramID = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
	SystemProgramID          = "11111111111111111111111111111111"
	MemoProgramID            = "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"
	ComputeBudgetProgramID   = "ComputeBudget111111111111111111111111111111"
)

// Single-byte instruction discriminators. These mirror the subscriptions
// program's instruction set order.
const (
	InstructionInitializeSubscriptionAuthority uint8 = 0
	InstructionCreateFixedDelegation           uint8 = 1
	InstructionCreateRecurringDelegation       uint8 = 2
	InstructionRevokeDelegation                uint8 = 3
	InstructionTransferFixed                   uint8 = 4
	InstructionTransferRecurring               uint8 = 5
	InstructionCloseSubscriptionAuthority      uint8 = 6
	InstructionCreatePlan                      uint8 = 7
	InstructionUpdatePlan                      uint8 = 8
	InstructionDeletePlan                      uint8 = 9
	InstructionTransferSubscription            uint8 = 10
	InstructionSubscribe                       uint8 = 11
	InstructionCancelSubscription              uint8 = 12
)

// DefaultProgramID parses the canonical mainnet program ID.
func DefaultProgramID() solana.PublicKey {
	return solana.MustPublicKeyFromBase58(SubscriptionsProgramID)
}

// ParsePubkey parses a base58 string into a PublicKey, returning a typed
// error labeling the field on failure.
func ParsePubkey(value, field string) (solana.PublicKey, error) {
	key, err := solana.PublicKeyFromBase58(value)
	if err != nil {
		return solana.PublicKey{}, fmt.Errorf("invalid %s pubkey: %w", field, err)
	}
	return key, nil
}

// FindSubscriptionAuthorityPDA derives the SubscriptionAuthority PDA for
// (subscriber, mint).
func FindSubscriptionAuthorityPDA(subscriber, mint, programID solana.PublicKey) (solana.PublicKey, uint8, error) {
	return solana.FindProgramAddress([][]byte{
		SubscriptionAuthoritySeed,
		subscriber.Bytes(),
		mint.Bytes(),
	}, programID)
}

// PlanIDSeed encodes a numeric plan_id as the 8-byte little-endian seed the
// on-chain program uses to derive the Plan PDA.
func PlanIDSeed(planID uint64) []byte {
	seed := make([]byte, 8)
	binary.LittleEndian.PutUint64(seed, planID)
	return seed
}

// FindPlanPDA derives the Plan PDA for (owner, planID). planID is treated as
// raw seed bytes; callers using the program's numeric PlanData.plan_id should
// pass PlanIDSeed(id).
func FindPlanPDA(owner solana.PublicKey, planID []byte, programID solana.PublicKey) (solana.PublicKey, uint8, error) {
	return solana.FindProgramAddress([][]byte{
		PlanSeed,
		owner.Bytes(),
		planID,
	}, programID)
}

// FindEventAuthorityPDA derives the program's event_authority PDA.
func FindEventAuthorityPDA(programID solana.PublicKey) (solana.PublicKey, uint8, error) {
	return solana.FindProgramAddress([][]byte{EventAuthoritySeed}, programID)
}

// FindSubscriptionPDA derives the SubscriptionDelegation PDA for
// (planPDA, subscriber).
func FindSubscriptionPDA(planPDA, subscriber, programID solana.PublicKey) (solana.PublicKey, uint8, error) {
	return solana.FindProgramAddress([][]byte{
		SubscriptionDelegationSeed,
		planPDA.Bytes(),
		subscriber.Bytes(),
	}, programID)
}

// ── Instruction data structs ────────────────────────────────────────────

// Plan layout sizing constants. The on-chain layout reserves 4 destination
// and 4 puller slots, plus a 128-byte metadata URI.
const (
	MaxPlanDestinations = 4
	MaxPlanPullers      = 4
	PlanMetadataURILen  = 128

	// CreatePlanDataLen is the serialized length of CreatePlan's data payload
	// (matches the program's PLAN_DATA_LEN_V1 = 456): plan_id(8) + mint(32) +
	// terms(24) + end_ts(8) + destinations(128) + pullers(128) + metadata(128).
	CreatePlanDataLen = 8 + 32 + 24 + 8 + 128 + 128 + 128

	// SubscribeDataLen is the serialized length of Subscribe's data payload (73).
	SubscribeDataLen = 8 + 1 + 32 + 8 + 8 + 8 + 8

	// TransferDataLen is the serialized length of the shared transfer data (72).
	TransferDataLen = 8 + 32 + 32
)

// PlanTerms are the immutable billing terms snapshotted into each
// SubscriptionDelegation at subscribe time.
type PlanTerms struct {
	// Amount is the maximum token amount that can be pulled per billing period.
	Amount uint64
	// PeriodHours is the billing period length in hours (1..=8760).
	PeriodHours uint64
	// CreatedAt is set by the program at plan creation; pass 0 on creation.
	CreatedAt int64
}

// CreatePlanData is the wire shape of CreatePlan instruction data (the
// program's PlanData).
type CreatePlanData struct {
	PlanID       uint64
	Mint         solana.PublicKey
	Terms        PlanTerms
	EndTS        int64
	Destinations [MaxPlanDestinations]solana.PublicKey
	Pullers      [MaxPlanPullers]solana.PublicKey
	MetadataURI  [PlanMetadataURILen]byte
}

// NewCreatePlanData constructs CreatePlanData from a metadata URI string. The
// URI is zero-padded to 128 bytes; an over-long URI is rejected so the error
// surfaces at the call site rather than silently truncating.
func NewCreatePlanData(
	planID uint64,
	mint solana.PublicKey,
	terms PlanTerms,
	endTS int64,
	destinations [MaxPlanDestinations]solana.PublicKey,
	pullers [MaxPlanPullers]solana.PublicKey,
	metadataURI string,
) (CreatePlanData, error) {
	if len(metadataURI) > PlanMetadataURILen {
		return CreatePlanData{}, fmt.Errorf("metadata_uri is %d bytes; max is %d", len(metadataURI), PlanMetadataURILen)
	}
	var padded [PlanMetadataURILen]byte
	copy(padded[:], metadataURI)
	return CreatePlanData{
		PlanID:       planID,
		Mint:         mint,
		Terms:        terms,
		EndTS:        endTS,
		Destinations: destinations,
		Pullers:      pullers,
		MetadataURI:  padded,
	}, nil
}

// ToBytes emits the discriminator-prefixed instruction data bytes.
func (d CreatePlanData) ToBytes() []byte {
	out := make([]byte, 0, 1+CreatePlanDataLen)
	out = append(out, InstructionCreatePlan)
	out = appendU64LE(out, d.PlanID)
	out = append(out, d.Mint.Bytes()...)
	out = appendU64LE(out, d.Terms.Amount)
	out = appendU64LE(out, d.Terms.PeriodHours)
	out = appendI64LE(out, d.Terms.CreatedAt)
	out = appendI64LE(out, d.EndTS)
	for _, dest := range d.Destinations {
		out = append(out, dest.Bytes()...)
	}
	for _, p := range d.Pullers {
		out = append(out, p.Bytes()...)
	}
	out = append(out, d.MetadataURI[:]...)
	return out
}

// SubscribeData is the wire shape of Subscribe instruction data.
type SubscribeData struct {
	PlanID                            uint64
	PlanBump                          uint8
	ExpectedMint                      solana.PublicKey
	ExpectedAmount                    uint64
	ExpectedPeriodHours               uint64
	ExpectedCreatedAt                 int64
	ExpectedSubscriptionAuthorityInit int64
}

// ToBytes emits the discriminator-prefixed instruction data bytes.
func (d SubscribeData) ToBytes() []byte {
	out := make([]byte, 0, 1+SubscribeDataLen)
	out = append(out, InstructionSubscribe)
	out = appendU64LE(out, d.PlanID)
	out = append(out, d.PlanBump)
	out = append(out, d.ExpectedMint.Bytes()...)
	out = appendU64LE(out, d.ExpectedAmount)
	out = appendU64LE(out, d.ExpectedPeriodHours)
	out = appendI64LE(out, d.ExpectedCreatedAt)
	out = appendI64LE(out, d.ExpectedSubscriptionAuthorityInit)
	return out
}

// TransferData is the wire shape of TransferSubscription (and the other
// transfer instructions). The program's TransferData is shared across Fixed,
// Recurring, and Subscription transfers.
type TransferData struct {
	Amount    uint64
	Delegator solana.PublicKey
	Mint      solana.PublicKey
}

// ToBytes emits the discriminator-prefixed instruction data bytes.
func (d TransferData) ToBytes(discriminator uint8) []byte {
	out := make([]byte, 0, 1+TransferDataLen)
	out = append(out, discriminator)
	out = appendU64LE(out, d.Amount)
	out = append(out, d.Delegator.Bytes()...)
	out = append(out, d.Mint.Bytes()...)
	return out
}

// ── Instruction account layouts + builders ──────────────────────────────
//
// Each builder mirrors the program's TryFrom<&[AccountView]> impl: the order,
// signer flag, and writable flag come directly from the program source.

// CreatePlanAccounts are the account inputs for BuildCreatePlanIx.
type CreatePlanAccounts struct {
	Merchant     solana.PublicKey
	PlanPDA      solana.PublicKey
	TokenMint    solana.PublicKey
	TokenProgram solana.PublicKey
}

// BuildCreatePlanIx builds a CreatePlan instruction. The system program is
// implied and supplied here.
func BuildCreatePlanIx(programID solana.PublicKey, accounts CreatePlanAccounts, data CreatePlanData) solana.Instruction {
	systemProgram := solana.MustPublicKeyFromBase58(SystemProgramID)
	return solana.NewInstruction(programID, solana.AccountMetaSlice{
		solana.Meta(accounts.Merchant).WRITE().SIGNER(),
		solana.Meta(accounts.PlanPDA).WRITE(),
		solana.Meta(accounts.TokenMint),
		solana.Meta(systemProgram),
		solana.Meta(accounts.TokenProgram),
	}, data.ToBytes())
}

// SubscribeAccounts are the account inputs for BuildSubscribeIx. Payer is
// optional: when zero, the subscriber funds rent.
type SubscribeAccounts struct {
	Subscriber               solana.PublicKey
	Merchant                 solana.PublicKey
	PlanPDA                  solana.PublicKey
	SubscriptionPDA          solana.PublicKey
	SubscriptionAuthorityPDA solana.PublicKey
	EventAuthority           solana.PublicKey
	Payer                    *solana.PublicKey
}

// BuildSubscribeIx builds a Subscribe instruction. Includes the optional
// payer account when supplied (the program reads it via resolve_optional_payer).
func BuildSubscribeIx(programID solana.PublicKey, accounts SubscribeAccounts, data SubscribeData) solana.Instruction {
	systemProgram := solana.MustPublicKeyFromBase58(SystemProgramID)
	metas := solana.AccountMetaSlice{
		solana.Meta(accounts.Subscriber).WRITE().SIGNER(),
		solana.Meta(accounts.Merchant),
		solana.Meta(accounts.PlanPDA),
		solana.Meta(accounts.SubscriptionPDA).WRITE(),
		solana.Meta(accounts.SubscriptionAuthorityPDA),
		solana.Meta(systemProgram),
		solana.Meta(accounts.EventAuthority),
		solana.Meta(programID),
	}
	if accounts.Payer != nil {
		metas = append(metas, solana.Meta(*accounts.Payer).WRITE().SIGNER())
	}
	return solana.NewInstruction(programID, metas, data.ToBytes())
}

// TransferSubscriptionAccounts are the account inputs for
// BuildTransferSubscriptionIx.
type TransferSubscriptionAccounts struct {
	SubscriptionPDA       solana.PublicKey
	PlanPDA               solana.PublicKey
	SubscriptionAuthority solana.PublicKey
	DelegatorATA          solana.PublicKey
	ReceiverATA           solana.PublicKey
	// Caller is the puller signing the transfer. Must match plan.owner or
	// appear in plan.pullers.
	Caller         solana.PublicKey
	TokenMint      solana.PublicKey
	TokenProgram   solana.PublicKey
	EventAuthority solana.PublicKey
}

// BuildTransferSubscriptionIx builds a TransferSubscription instruction.
func BuildTransferSubscriptionIx(programID solana.PublicKey, accounts TransferSubscriptionAccounts, data TransferData) solana.Instruction {
	return solana.NewInstruction(programID, solana.AccountMetaSlice{
		solana.Meta(accounts.SubscriptionPDA).WRITE(),
		solana.Meta(accounts.PlanPDA),
		solana.Meta(accounts.SubscriptionAuthority),
		solana.Meta(accounts.DelegatorATA).WRITE(),
		solana.Meta(accounts.ReceiverATA).WRITE(),
		solana.Meta(accounts.Caller).SIGNER(),
		solana.Meta(accounts.TokenMint),
		solana.Meta(accounts.TokenProgram),
		solana.Meta(accounts.EventAuthority),
		solana.Meta(programID),
	}, data.ToBytes(InstructionTransferSubscription))
}

// CancelSubscriptionAccounts are the account inputs for
// BuildCancelSubscriptionIx.
type CancelSubscriptionAccounts struct {
	Subscriber      solana.PublicKey
	PlanPDA         solana.PublicKey
	SubscriptionPDA solana.PublicKey
	EventAuthority  solana.PublicKey
}

// BuildCancelSubscriptionIx builds a CancelSubscription instruction. No data
// beyond the discriminator.
func BuildCancelSubscriptionIx(programID solana.PublicKey, accounts CancelSubscriptionAccounts) solana.Instruction {
	return solana.NewInstruction(programID, solana.AccountMetaSlice{
		solana.Meta(accounts.Subscriber).WRITE().SIGNER(),
		solana.Meta(accounts.PlanPDA),
		solana.Meta(accounts.SubscriptionPDA).WRITE(),
		solana.Meta(accounts.EventAuthority),
		solana.Meta(programID),
	}, []byte{InstructionCancelSubscription})
}

// InitializeSubscriptionAuthorityAccounts are the account inputs for
// BuildInitializeSubscriptionAuthorityIx.
type InitializeSubscriptionAuthorityAccounts struct {
	Owner                 solana.PublicKey
	SubscriptionAuthority solana.PublicKey
	TokenMint             solana.PublicKey
	UserATA               solana.PublicKey
	TokenProgram          solana.PublicKey
}

// BuildInitializeSubscriptionAuthorityIx builds an InitSubscriptionAuthority
// instruction. No data beyond the discriminator.
func BuildInitializeSubscriptionAuthorityIx(programID solana.PublicKey, accounts InitializeSubscriptionAuthorityAccounts) solana.Instruction {
	systemProgram := solana.MustPublicKeyFromBase58(SystemProgramID)
	return solana.NewInstruction(programID, solana.AccountMetaSlice{
		solana.Meta(accounts.Owner).WRITE().SIGNER(),
		solana.Meta(accounts.SubscriptionAuthority).WRITE(),
		solana.Meta(accounts.TokenMint),
		solana.Meta(accounts.UserATA).WRITE(),
		solana.Meta(systemProgram),
		solana.Meta(accounts.TokenProgram),
	}, []byte{InstructionInitializeSubscriptionAuthority})
}

func appendU64LE(buf []byte, v uint64) []byte {
	var b [8]byte
	binary.LittleEndian.PutUint64(b[:], v)
	return append(buf, b[:]...)
}

func appendI64LE(buf []byte, v int64) []byte {
	return appendU64LE(buf, uint64(v))
}
