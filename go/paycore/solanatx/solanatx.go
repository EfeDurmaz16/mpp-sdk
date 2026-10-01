// Package solanatx holds the protocol-agnostic Solana-toolchain glue
// shared by every protocol: a minimal Signer interface, an RPCClient
// interface mirroring the subset of the official Solana Go RPC client
// the SDK depends on, plus helpers to build SOL / SPL transfer /
// associated-token-account / compute-budget / memo instructions, decode
// transactions, split amounts, and run the simulate-broadcast-confirm
// sequence. It is a PayCore primitive and imports no protocol package;
// the public SDK surface lives in the protocols/* and pay-kit packages.
package solanatx

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"math/bits"
	"strconv"
	"time"

	bin "github.com/gagliardetto/binary"
	solana "github.com/solana-foundation/solana-go/v2"
	computebudget "github.com/solana-foundation/solana-go/v2/programs/compute-budget"
	"github.com/solana-foundation/solana-go/v2/programs/system"
	"github.com/solana-foundation/solana-go/v2/programs/token"
	token2022 "github.com/solana-foundation/solana-go/v2/programs/token-2022"
	"github.com/solana-foundation/solana-go/v2/rpc"

	"github.com/solana-foundation/pay-kit/go/paycore"
	keychain "github.com/solana-foundation/solana-keychain/go/core/v2"
)

// Signer is the minimal signer surface shared by the client and server packages.
type Signer interface {
	PublicKey() solana.PublicKey
	Sign(payload []byte) (solana.Signature, error)
}

// RPCClient captures the RPC methods used by the SDK.
type RPCClient interface {
	GetAccountInfoWithOpts(context.Context, solana.PublicKey, *rpc.GetAccountInfoOpts) (*rpc.GetAccountInfoResult, error)
	GetLatestBlockhash(context.Context, rpc.CommitmentType) (*rpc.GetLatestBlockhashResult, error)
	GetSignatureStatuses(context.Context, bool, ...solana.Signature) (*rpc.GetSignatureStatusesResult, error)
	GetTransaction(context.Context, solana.Signature, *rpc.GetTransactionOpts) (*rpc.GetTransactionResult, error)
	SendTransactionWithOpts(context.Context, *solana.Transaction, rpc.TransactionOpts) (solana.Signature, error)
	SimulateTransactionWithOpts(context.Context, *solana.Transaction, *rpc.SimulateTransactionOpts) (*rpc.SimulateTransactionResponse, error)
}

// BuildSOLTransfer appends a native SOL transfer.
func BuildSOLTransfer(from, to solana.PublicKey, lamports uint64) (solana.Instruction, error) {
	return system.NewTransferInstruction(lamports, from, to).ValidateAndBuild()
}

// BuildComputeUnitLimit appends a compute budget limit instruction.
func BuildComputeUnitLimit(units uint32) (solana.Instruction, error) {
	return computebudget.NewSetComputeUnitLimitInstruction(units).ValidateAndBuild()
}

// BuildComputeUnitPrice appends a compute budget price instruction.
func BuildComputeUnitPrice(microLamports uint64) (solana.Instruction, error) {
	return computebudget.NewSetComputeUnitPriceInstruction(microLamports).ValidateAndBuild()
}

// BuildMemoInstruction builds a Solana Memo Program instruction.
func BuildMemoInstruction(memo string) (solana.Instruction, error) {
	if len([]byte(memo)) > 566 {
		return nil, fmt.Errorf("memo cannot exceed 566 bytes")
	}
	programID, err := solana.PublicKeyFromBase58(paycore.MemoProgram)
	if err != nil {
		return nil, err
	}
	return solana.NewInstruction(programID, solana.AccountMetaSlice{}, []byte(memo)), nil
}

// BuildCreateAssociatedTokenAccount creates an idempotent ATA create instruction.
func BuildCreateAssociatedTokenAccount(payer, wallet, mint, tokenProgram solana.PublicKey) (solana.Instruction, error) {
	ata, err := FindAssociatedTokenAddressWithProgram(wallet, mint, tokenProgram)
	if err != nil {
		return nil, err
	}
	return solana.NewInstruction(
		solana.SPLAssociatedTokenAccountProgramID,
		solana.AccountMetaSlice{
			solana.Meta(payer).WRITE().SIGNER(),
			solana.Meta(ata).WRITE(),
			solana.Meta(wallet),
			solana.Meta(mint),
			solana.Meta(solana.SystemProgramID),
			solana.Meta(tokenProgram),
		},
		[]byte{1},
	), nil
}

// BuildTransferChecked builds a token transfer checked instruction.
func BuildTransferChecked(amount uint64, decimals uint8, source, mint, destination, owner, tokenProgram solana.PublicKey) (solana.Instruction, error) {
	if tokenProgram.Equals(solana.TokenProgramID) {
		return token.NewTransferCheckedInstruction(amount, decimals, source, mint, destination, owner, nil).ValidateAndBuild()
	}
	if tokenProgram.Equals(solana.MustPublicKeyFromBase58(paycore.Token2022Program)) {
		return token2022.NewTransferCheckedInstruction(amount, decimals, source, mint, destination, owner, nil).ValidateAndBuild()
	}
	return nil, fmt.Errorf("unsupported token program %s", tokenProgram)
}

// FindAssociatedTokenAddress derives the ATA for a wallet and mint.
func FindAssociatedTokenAddress(wallet, mint solana.PublicKey) (solana.PublicKey, error) {
	ata, _, err := solana.FindAssociatedTokenAddress(wallet, mint)
	return ata, err
}

// FindAssociatedTokenAddressWithProgram derives an ATA for either Token or Token-2022.
func FindAssociatedTokenAddressWithProgram(wallet, mint, tokenProgram solana.PublicKey) (solana.PublicKey, error) {
	if tokenProgram.Equals(solana.TokenProgramID) {
		return FindAssociatedTokenAddress(wallet, mint)
	}
	address, _, err := solana.FindProgramAddress([][]byte{
		wallet[:],
		tokenProgram[:],
		mint[:],
	}, solana.SPLAssociatedTokenAccountProgramID)
	return address, err
}

// NewV0Transaction assembles a version 0 transaction with only static
// account keys (no address-table lookups). Clients never build legacy
// messages, so every client path builds through here; servers still accept
// legacy from pre-cutover clients (see DecodeTransaction).
func NewV0Transaction(instructions []solana.Instruction, recentBlockhash solana.Hash, opts ...solana.TransactionOption) (*solana.Transaction, error) {
	tx, err := solana.NewTransaction(instructions, recentBlockhash, opts...)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Message.SetVersion(solana.MessageVersionV0); err != nil {
		return nil, err
	}
	return tx, nil
}

// EncodeTransactionBase64 returns a base64 wire transaction.
func EncodeTransactionBase64(tx *solana.Transaction) (string, error) {
	wire, err := tx.MarshalBinary()
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(wire), nil
}

// DecodeTransaction decodes a wire transaction supplied by a client and
// enforces the message-version policy every server verifier shares: version
// 0 and legacy (unprefixed) messages are accepted, and any other version
// (version 1 is not yet enabled by pay-kit) is rejected cleanly. A legacy message
// is policed exactly like version 0 (same size limit, ComputeBudget
// instructions in the body, no address lookup tables) and is kept only for
// existing clients: pay-kit clients never build one.
func DecodeTransaction(wire []byte) (*solana.Transaction, error) {
	if err := checkWireVersion(wire); err != nil {
		return nil, err
	}
	tx := new(solana.Transaction)
	if err := tx.UnmarshalWithDecoder(bin.NewBinDecoder(wire)); err != nil {
		return nil, err
	}
	switch version := tx.Message.GetVersion(); version {
	case solana.MessageVersionLegacy, solana.MessageVersionV0:
		return tx, nil
	default:
		// solana-go stores the prefix byte minus 0x7f, so v0 is 1 and v1 is 2.
		return nil, fmt.Errorf("unsupported transaction message version %d", int(version)-1)
	}
}

// DecodeTransactionBase64 decodes a base64 wire transaction through
// DecodeTransaction.
func DecodeTransactionBase64(encoded string) (*solana.Transaction, error) {
	wire, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	return DecodeTransaction(wire)
}

// ErrMissingTransactionVersion is returned by CheckReportedVersion when a
// getTransaction result carries no version field; the text matches the Rust
// server (core::tx::check_reported_version).
var ErrMissingTransactionVersion = errors.New("RPC did not report the transaction version")

// CheckReportedVersion enforces the message-version policy on the version
// field of a getTransaction result, so signature-credential server paths
// apply the same policy as DecodeTransaction before consuming a landed
// transaction. version is the field as reported: nil when absent, "legacy"
// for a legacy message, or the numeric message version
// (rpc.TransactionVersion from a typed result, float64 from raw JSON).
// Legacy, 0 and 1 are accepted; a missing version is not, since nodes report
// one for every transaction once asked.
func CheckReportedVersion(version any) error {
	switch v := version.(type) {
	case nil:
		return ErrMissingTransactionVersion
	case rpc.TransactionVersion:
		if v == rpc.LegacyTransactionVersion || v == 0 || v == 1 {
			return nil
		}
	case float64:
		if v == 0 || v == 1 {
			return nil
		}
	case string:
		if v == "legacy" {
			return nil
		}
	}
	return fmt.Errorf("unsupported transaction version %v", version)
}

// TransactionSigner optionally exposes Keychain transaction-aware signing.
// Message-only custom signers remain supported through SignTransactionWith.
type TransactionSigner interface {
	Signer
	SignTransaction(context.Context, *solana.Transaction) (keychain.SignedTransaction, error)
}

// SignTransaction keeps the existing context-free API for custom signers.
func SignTransaction(tx *solana.Transaction, signer Signer) error {
	return SignTransactionContext(context.Background(), tx, signer)
}

// SignTransactionContext adds a signature through Keychain without broadcasting
// or requiring all other signatures to be present.
func SignTransactionContext(ctx context.Context, tx *solana.Transaction, signer Signer) error {
	if transactionSigner, ok := signer.(TransactionSigner); ok {
		_, err := transactionSigner.SignTransaction(ctx, tx)
		return err
	}
	_, err := keychain.SignTransactionWith(ctx, tx, signer.PublicKey(),
		func(_ context.Context, message []byte) (solana.Signature, error) {
			return signer.Sign(message)
		})
	return err
}

// FromKeychain adapts a sign-only backend for protocol client and server options.
// Message signing stays separate for off-chain vouchers.
func FromKeychain(backend keychain.TransactionSigner) Signer {
	return keychainSigner{TransactionSigner: backend}
}

type keychainSigner struct {
	keychain.TransactionSigner
}

func (s keychainSigner) PublicKey() solana.PublicKey { return s.Pubkey() }
func (s keychainSigner) Sign(message []byte) (solana.Signature, error) {
	return s.SignMessage(context.Background(), message)
}

// ResolveTokenProgram resolves the mint owner into the token program ID.
func ResolveTokenProgram(ctx context.Context, rpcClient RPCClient, mint solana.PublicKey, tokenProgramHint string) (solana.PublicKey, error) {
	if tokenProgramHint != "" {
		return solana.PublicKeyFromBase58(tokenProgramHint)
	}
	account, err := rpcClient.GetAccountInfoWithOpts(ctx, mint, &rpc.GetAccountInfoOpts{
		Commitment: rpc.CommitmentConfirmed,
		Encoding:   solana.EncodingBase64,
	})
	if err != nil {
		return solana.PublicKey{}, err
	}
	if account.Value == nil {
		return solana.PublicKey{}, fmt.Errorf("mint account not found")
	}
	switch account.Value.Owner.String() {
	case paycore.TokenProgram:
		return solana.TokenProgramID, nil
	case paycore.Token2022Program:
		return solana.MustPublicKeyFromBase58(paycore.Token2022Program), nil
	default:
		return solana.PublicKey{}, fmt.Errorf("unsupported mint owner %s", account.Value.Owner)
	}
}

// ResolveRecentBlockhash returns the provided blockhash or fetches one from RPC.
func ResolveRecentBlockhash(ctx context.Context, rpcClient RPCClient, provided string) (solana.Hash, error) {
	if provided != "" {
		return solana.HashFromBase58(provided)
	}
	out, err := rpcClient.GetLatestBlockhash(ctx, rpc.CommitmentConfirmed)
	if err != nil {
		return solana.Hash{}, err
	}
	return out.Value.Blockhash, nil
}

// WaitForConfirmation polls the RPC until a signature reaches confirmed/finalized.
func WaitForConfirmation(ctx context.Context, rpcClient RPCClient, signature solana.Signature) error {
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		out, err := rpcClient.GetSignatureStatuses(ctx, true, signature)
		if err == nil && out != nil && len(out.Value) > 0 && out.Value[0] != nil {
			status := out.Value[0]
			if status.Err != nil {
				return fmt.Errorf("transaction failed on-chain: %v", status.Err)
			}
			if status.ConfirmationStatus == rpc.ConfirmationStatusConfirmed || status.ConfirmationStatus == rpc.ConfirmationStatusFinalized || status.Confirmations == nil {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

// SimulateTransaction runs preflight simulation.
func SimulateTransaction(ctx context.Context, rpcClient RPCClient, tx *solana.Transaction) error {
	out, err := rpcClient.SimulateTransactionWithOpts(ctx, tx, &rpc.SimulateTransactionOpts{
		Commitment: rpc.CommitmentConfirmed,
		SigVerify:  true,
	})
	if err != nil {
		return err
	}
	if out != nil && out.Value != nil && out.Value.Err != nil {
		return fmt.Errorf("simulation failed: %v", out.Value.Err)
	}
	return nil
}

// SendTransaction submits the transaction to the cluster.
func SendTransaction(ctx context.Context, rpcClient RPCClient, tx *solana.Transaction) (solana.Signature, error) {
	return rpcClient.SendTransactionWithOpts(ctx, tx, rpc.TransactionOpts{
		SkipPreflight:       false,
		PreflightCommitment: rpc.CommitmentConfirmed,
	})
}

// FetchTransaction reads a confirmed transaction back by signature and
// returns it decoded plus meta. The version the RPC reports is checked with
// CheckReportedVersion and the returned wire bytes go through
// DecodeTransaction, so a landed transaction is held to the same version
// policy as client-supplied bytes.
func FetchTransaction(ctx context.Context, rpcClient RPCClient, signature solana.Signature) (*solana.Transaction, *rpc.TransactionMeta, error) {
	maxVersion := uint64(1)
	result, err := rpcClient.GetTransaction(ctx, signature, &rpc.GetTransactionOpts{
		Commitment:                     rpc.CommitmentConfirmed,
		Encoding:                       solana.EncodingBase64,
		MaxSupportedTransactionVersion: &maxVersion,
	})
	if err != nil {
		return nil, nil, err
	}
	if result == nil || result.Transaction == nil {
		return nil, nil, errors.New("RPC returned no transaction")
	}
	// solana-go decodes an absent version field as 0; the wire decode below
	// still applies the version policy to the bytes themselves.
	if err := CheckReportedVersion(result.Version); err != nil {
		return nil, nil, err
	}
	tx, err := DecodeTransaction(result.Transaction.GetBinary())
	if err != nil {
		return nil, nil, err
	}
	return tx, result.Meta, nil
}

// SplitAmounts computes the primary transfer amount and validates the split set.
func SplitAmounts(total uint64, splits []paycore.Split) (uint64, error) {
	if len(splits) > 8 {
		return 0, paycore.NewError(paycore.ErrCodeTooManySplits, "splits exceed maximum of 8 entries")
	}
	var splitTotal uint64
	for _, split := range splits {
		amount, err := strconv.ParseUint(split.Amount, 10, 64)
		if err != nil {
			return 0, fmt.Errorf("invalid split amount %q", split.Amount)
		}
		sum, carry := bits.Add64(splitTotal, amount, 0)
		if carry != 0 {
			return 0, paycore.NewError(paycore.ErrCodeSplitsExceed, "splits consume the entire amount")
		}
		splitTotal = sum
	}
	if splitTotal >= total {
		return 0, paycore.NewError(paycore.ErrCodeSplitsExceed, "splits consume the entire amount")
	}
	return total - splitTotal, nil
}
