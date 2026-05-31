// Package program carries typed helpers for the on-chain payment-channels
// program used by the MPP session intent: channel PDA derivation,
// associated-token derivation, the blake3 distribution hash, the Borsh
// voucher signing bytes, the Ed25519 precompile verify instruction, and
// the Open / TopUp instruction builders.
//
// Byte layouts mirror rust/crates/mpp/src/program/payment_channels.rs
// exactly so cross-language vouchers and PDAs match. The voucher signing
// bytes are channel_id(32) || cumulative_amount(u64 LE,8) ||
// expires_at(i64 LE,8) = 48 bytes, signed with Ed25519.
package program

import (
	"encoding/binary"
	"fmt"

	solana "github.com/gagliardetto/solana-go"
	"lukechampine.com/blake3"
)

// PaymentChannelsProgramID is the canonical payment-channels program ID
// deployed to Surfnet. Mirrors PAYMENT_CHANNELS_PROGRAM_ID in the Rust spine.
const PaymentChannelsProgramID = "GuoKrzaBiZnW5DvJ3yZVE7xHqbcBvaX9SH6P6Cn9gNvc"

// Seed prefixes and sysvar / precompile IDs used by the program.
const (
	// ChannelSeed is the channel PDA seed prefix.
	ChannelSeed = "channel"
	// EventAuthoritySeed is the event authority PDA seed prefix.
	EventAuthoritySeed = "event_authority"
	// Ed25519ProgramID is the Ed25519 signature-verify precompile program ID.
	Ed25519ProgramID = "Ed25519SigVerify111111111111111111111111111"
	// InstructionsSysvarID is the instructions sysvar account ID.
	InstructionsSysvarID = "Sysvar1nstructions1111111111111111111111111"
	// RentSysvarID is the rent sysvar account ID.
	RentSysvarID = "SysvarRent111111111111111111111111111111111"
)

// VoucherMessageLen is the length of the Borsh voucher signing message.
const VoucherMessageLen = 48

// Distribution is a single split recipient with a basis-point share.
type Distribution struct {
	Recipient solana.PublicKey
	Bps       uint16
}

// DefaultProgramID returns the canonical payment-channels program ID.
func DefaultProgramID() solana.PublicKey {
	return solana.MustPublicKeyFromBase58(PaymentChannelsProgramID)
}

// FindChannelPDA derives the channel PDA. Seed order mirrors the Rust spine:
// "channel" || payer || payee || mint || authorizedSigner || salt(u64 LE).
func FindChannelPDA(
	payer, payee, mint, authorizedSigner solana.PublicKey,
	salt uint64,
	programID solana.PublicKey,
) (solana.PublicKey, uint8, error) {
	saltLE := make([]byte, 8)
	binary.LittleEndian.PutUint64(saltLE, salt)
	pda, bump, err := solana.FindProgramAddress([][]byte{
		[]byte(ChannelSeed),
		payer[:],
		payee[:],
		mint[:],
		authorizedSigner[:],
		saltLE,
	}, programID)
	return pda, bump, err
}

// FindEventAuthorityPDA derives the event authority PDA for the program.
func FindEventAuthorityPDA(programID solana.PublicKey) (solana.PublicKey, uint8, error) {
	return solana.FindProgramAddress([][]byte{[]byte(EventAuthoritySeed)}, programID)
}

// FindAssociatedTokenAddress derives the ATA for the given owner, mint, and
// token program. Seed order is owner || tokenProgram || mint under the
// associated-token program, matching the Rust spine.
func FindAssociatedTokenAddress(owner, mint, tokenProgram solana.PublicKey) (solana.PublicKey, uint8, error) {
	return solana.FindProgramAddress([][]byte{
		owner[:],
		tokenProgram[:],
		mint[:],
	}, solana.SPLAssociatedTokenAccountProgramID)
}

// DistributionHash returns the 32-byte blake3 distribution hash committed
// at channel open. Preimage is count(u32 LE) followed by each
// recipient(32) || bps(u16 LE), matching distribution_hash in the Rust spine.
func DistributionHash(recipients []Distribution) [32]byte {
	hasher := blake3.New(32, nil)
	countLE := make([]byte, 4)
	binary.LittleEndian.PutUint32(countLE, uint32(len(recipients)))
	_, _ = hasher.Write(countLE)
	bpsLE := make([]byte, 2)
	for _, r := range recipients {
		_, _ = hasher.Write(r.Recipient[:])
		binary.LittleEndian.PutUint16(bpsLE, r.Bps)
		_, _ = hasher.Write(bpsLE)
	}
	var out [32]byte
	copy(out[:], hasher.Sum(nil))
	return out
}

// VoucherMessageBytes returns the Borsh VoucherArgs bytes signed by Ed25519:
// channelID(32) || cumulativeAmount(u64 LE) || expiresAt(i64 LE).
func VoucherMessageBytes(channelID solana.PublicKey, cumulativeAmount uint64, expiresAt int64) []byte {
	out := make([]byte, VoucherMessageLen)
	copy(out[:32], channelID[:])
	binary.LittleEndian.PutUint64(out[32:40], cumulativeAmount)
	binary.LittleEndian.PutUint64(out[40:48], uint64(expiresAt))
	return out
}

// BuildEd25519VerifyInstruction builds the Ed25519 precompile verify
// instruction over the voucher message. Layout mirrors
// build_ed25519_verify_instruction in the Rust spine.
func BuildEd25519VerifyInstruction(
	authorizedSigner solana.PublicKey,
	signature [64]byte,
	message []byte,
) (solana.Instruction, error) {
	const publicKeyOffset uint16 = 16
	const signatureOffset uint16 = publicKeyOffset + 32
	const messageDataOffset uint16 = signatureOffset + 64
	const currentInstruction uint16 = 0xFFFF
	if len(message) > 0xFFFF {
		return nil, fmt.Errorf("voucher message too large for ed25519 instruction")
	}
	messageDataSize := uint16(len(message))

	data := make([]byte, 0, int(messageDataOffset)+len(message))
	data = append(data, 1, 0) // count=1, padding=0
	data = appendU16LE(data, signatureOffset)
	data = appendU16LE(data, currentInstruction)
	data = appendU16LE(data, publicKeyOffset)
	data = appendU16LE(data, currentInstruction)
	data = appendU16LE(data, messageDataOffset)
	data = appendU16LE(data, messageDataSize)
	data = appendU16LE(data, currentInstruction)
	data = append(data, authorizedSigner[:]...)
	data = append(data, signature[:]...)
	data = append(data, message...)

	return solana.NewInstruction(
		solana.MustPublicKeyFromBase58(Ed25519ProgramID),
		solana.AccountMetaSlice{},
		data,
	), nil
}

func appendU16LE(buf []byte, value uint16) []byte {
	return append(buf, byte(value), byte(value>>8))
}

// Anchor instruction discriminators for the payment-channels program.
const (
	openDiscriminator  byte = 1
	topUpDiscriminator byte = 3
)

// OpenChannelParams carries everything needed to derive the channel
// addresses and build the Open instruction.
type OpenChannelParams struct {
	Payer            solana.PublicKey
	Payee            solana.PublicKey
	Mint             solana.PublicKey
	AuthorizedSigner solana.PublicKey
	Salt             uint64
	Deposit          uint64
	GracePeriod      uint32
	Recipients       []Distribution
	TokenProgram     solana.PublicKey
	ProgramID        solana.PublicKey
}

// ChannelAddresses holds the derived accounts for a channel open.
type ChannelAddresses struct {
	Channel             solana.PublicKey
	PayerTokenAccount   solana.PublicKey
	ChannelTokenAccount solana.PublicKey
	EventAuthority      solana.PublicKey
}

// DeriveChannelAddresses derives the channel PDA, the payer and channel
// associated token accounts, and the event authority PDA.
func DeriveChannelAddresses(params OpenChannelParams) (ChannelAddresses, error) {
	channel, _, err := FindChannelPDA(params.Payer, params.Payee, params.Mint, params.AuthorizedSigner, params.Salt, params.ProgramID)
	if err != nil {
		return ChannelAddresses{}, err
	}
	payerATA, _, err := FindAssociatedTokenAddress(params.Payer, params.Mint, params.TokenProgram)
	if err != nil {
		return ChannelAddresses{}, err
	}
	channelATA, _, err := FindAssociatedTokenAddress(channel, params.Mint, params.TokenProgram)
	if err != nil {
		return ChannelAddresses{}, err
	}
	eventAuthority, _, err := FindEventAuthorityPDA(params.ProgramID)
	if err != nil {
		return ChannelAddresses{}, err
	}
	return ChannelAddresses{
		Channel:             channel,
		PayerTokenAccount:   payerATA,
		ChannelTokenAccount: channelATA,
		EventAuthority:      eventAuthority,
	}, nil
}

// encodeOpenArgs Borsh-encodes OpenArgs:
// salt(u64 LE) || deposit(u64 LE) || gracePeriod(u32 LE) ||
// recipients(vec: u32 LE len, then recipient(32) || bps(u16 LE)).
func encodeOpenArgs(params OpenChannelParams) []byte {
	buf := make([]byte, 0, 8+8+4+4+len(params.Recipients)*34)
	u64 := make([]byte, 8)
	binary.LittleEndian.PutUint64(u64, params.Salt)
	buf = append(buf, u64...)
	binary.LittleEndian.PutUint64(u64, params.Deposit)
	buf = append(buf, u64...)
	u32 := make([]byte, 4)
	binary.LittleEndian.PutUint32(u32, params.GracePeriod)
	buf = append(buf, u32...)
	binary.LittleEndian.PutUint32(u32, uint32(len(params.Recipients)))
	buf = append(buf, u32...)
	for _, r := range params.Recipients {
		buf = append(buf, r.Recipient[:]...)
		buf = appendU16LE(buf, r.Bps)
	}
	return buf
}

// BuildOpenInstruction builds the payment-channels Open instruction. The
// account order and Borsh arg encoding mirror the generated Codama client
// used by the Rust spine (discriminator 1, 13 accounts).
func BuildOpenInstruction(params OpenChannelParams) (solana.Instruction, error) {
	addresses, err := DeriveChannelAddresses(params)
	if err != nil {
		return nil, err
	}
	data := append([]byte{openDiscriminator}, encodeOpenArgs(params)...)
	accounts := solana.AccountMetaSlice{
		solana.Meta(params.Payer).WRITE().SIGNER(),
		solana.Meta(params.Payee),
		solana.Meta(params.Mint),
		solana.Meta(params.AuthorizedSigner),
		solana.Meta(addresses.Channel).WRITE(),
		solana.Meta(addresses.PayerTokenAccount).WRITE(),
		solana.Meta(addresses.ChannelTokenAccount).WRITE(),
		solana.Meta(params.TokenProgram),
		solana.Meta(solana.SystemProgramID),
		solana.Meta(solana.MustPublicKeyFromBase58(RentSysvarID)),
		solana.Meta(solana.SPLAssociatedTokenAccountProgramID),
		solana.Meta(addresses.EventAuthority),
		solana.Meta(params.ProgramID),
	}
	return solana.NewInstruction(params.ProgramID, accounts, data), nil
}

// BuildTopUpInstruction builds the payment-channels TopUp instruction
// (discriminator 3, 6 accounts) raising a channel's deposit by amount.
func BuildTopUpInstruction(
	payer, channel, mint solana.PublicKey,
	amount uint64,
	tokenProgram, programID solana.PublicKey,
) (solana.Instruction, error) {
	payerATA, _, err := FindAssociatedTokenAddress(payer, mint, tokenProgram)
	if err != nil {
		return nil, err
	}
	channelATA, _, err := FindAssociatedTokenAddress(channel, mint, tokenProgram)
	if err != nil {
		return nil, err
	}
	u64 := make([]byte, 8)
	binary.LittleEndian.PutUint64(u64, amount)
	data := append([]byte{topUpDiscriminator}, u64...)
	accounts := solana.AccountMetaSlice{
		solana.Meta(payer).WRITE().SIGNER(),
		solana.Meta(channel).WRITE(),
		solana.Meta(payerATA).WRITE(),
		solana.Meta(channelATA).WRITE(),
		solana.Meta(mint),
		solana.Meta(tokenProgram),
	}
	return solana.NewInstruction(programID, accounts, data), nil
}
