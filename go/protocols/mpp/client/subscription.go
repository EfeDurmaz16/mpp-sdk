package client

import (
	"context"
	"encoding/binary"
	"fmt"

	solana "github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/rpc"

	"github.com/solana-foundation/pay-kit/go/paycore"
	"github.com/solana-foundation/pay-kit/go/paycore/solanatx"
	"github.com/solana-foundation/pay-kit/go/paycore/subscriptions"
	core "github.com/solana-foundation/pay-kit/go/protocols/mpp/core"
)

// subscriptionAuthorityAccountLen is the raw byte length of the on-chain
// SubscriptionAuthority PDA. Mirrors #[repr(C, packed)]: discriminator(1) +
// user(32) + token_mint(32) + payer(32) + bump(1) + init_id(8) = 106.
const subscriptionAuthorityAccountLen = 1 + 32 + 32 + 32 + 1 + 8

// subscriptionAuthorityInitIDOffset is the offset of init_id (i64 LE) inside a
// serialized SubscriptionAuthority.
const subscriptionAuthorityInitIDOffset = 1 + 32 + 32 + 32 + 1

// SubscriptionActivationOptions customize the subscription activation
// transaction build.
type SubscriptionActivationOptions struct {
	// ExternalID, when set, is embedded as a trailing memo instruction.
	ExternalID string
	// ComputeUnitLimit defaults to 400,000 (activation runs up to three
	// subscriptions-program instructions plus token transfers).
	ComputeUnitLimit uint32
	// ComputeUnitPrice in microlamports defaults to 1.
	ComputeUnitPrice uint64
	// SubscriptionAuthorityInitID, when set, pins the
	// SubscriptionAuthority::init_id so the builder skips the on-chain SA
	// lookup and the init-tx broadcast. Useful for tests and callers that have
	// already resolved the SA state.
	SubscriptionAuthorityInitID *int64
}

// BuildSubscriptionActivationTransaction builds the subscription activation
// transaction defined by the Solana subscription profile:
//
//	[compute_budget_price, compute_budget_limit, create_idempotent_ata,
//	 subscribe, transfer_subscription, memo(externalId)?]
//
// SubscriptionAuthority init runs as a separate pre-broadcast tx, not bundled
// into the activation. The activation tx is signed as the subscriber; when the
// server is fee payer, the tx is returned partially signed and the server adds
// the fee-payer signature before broadcasting. Mirrors
// rust/src/client/subscription.rs.
func BuildSubscriptionActivationTransaction(
	ctx context.Context,
	signer solanatx.Signer,
	rpcClient solanatx.RPCClient,
	details paycore.SubscriptionMethodDetails,
	options SubscriptionActivationOptions,
) (paycore.CredentialPayload, error) {
	programID := subscriptions.DefaultProgramID()
	if details.ProgramID != "" {
		parsed, err := subscriptions.ParsePubkey(details.ProgramID, "programId")
		if err != nil {
			return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeInvalidConfig, "parse programId", err)
		}
		programID = parsed
	}

	subscriber := signer.PublicKey()
	mint, err := subscriptions.ParsePubkey(details.Mint, "mint")
	if err != nil {
		return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeInvalidConfig, "parse mint", err)
	}
	tokenProgram, err := subscriptions.ParsePubkey(details.TokenProgram, "tokenProgram")
	if err != nil {
		return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeInvalidConfig, "parse tokenProgram", err)
	}
	planPDA, err := subscriptions.ParsePubkey(details.PlanID, "planId")
	if err != nil {
		return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeInvalidConfig, "parse planId", err)
	}
	puller, err := subscriptions.ParsePubkey(details.Puller, "puller")
	if err != nil {
		return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeInvalidConfig, "parse puller", err)
	}
	// Plan owner defaults to the puller when the operator publishes its own
	// plan and is its own puller (the common server case).
	merchant := puller
	if details.Merchant != "" {
		merchant, err = subscriptions.ParsePubkey(details.Merchant, "merchant")
		if err != nil {
			return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeInvalidConfig, "parse merchant", err)
		}
	}
	recipient := puller
	if details.Recipient != "" {
		recipient, err = subscriptions.ParsePubkey(details.Recipient, "recipient")
		if err != nil {
			return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeInvalidConfig, "parse recipient", err)
		}
	}

	subscriptionAuthority, _, err := subscriptions.FindSubscriptionAuthorityPDA(subscriber, mint, programID)
	if err != nil {
		return paycore.CredentialPayload{}, err
	}
	subscriptionPDA, _, err := subscriptions.FindSubscriptionPDA(planPDA, subscriber, programID)
	if err != nil {
		return paycore.CredentialPayload{}, err
	}
	eventAuthority, _, err := subscriptions.FindEventAuthorityPDA(programID)
	if err != nil {
		return paycore.CredentialPayload{}, err
	}

	subscriberATA, err := solanatx.FindAssociatedTokenAddressWithProgram(subscriber, mint, tokenProgram)
	if err != nil {
		return paycore.CredentialPayload{}, err
	}
	recipientATA, err := solanatx.FindAssociatedTokenAddressWithProgram(recipient, mint, tokenProgram)
	if err != nil {
		return paycore.CredentialPayload{}, err
	}

	// Required SubscribeData fields the on-chain program reads to validate the
	// subscriber consented to the live Plan terms.
	if details.PlanIDNumeric == nil {
		return paycore.CredentialPayload{}, core.NewError(core.ErrCodeInvalidConfig,
			"methodDetails.planIdNumeric is required to build SubscribeData")
	}
	if details.PlanBump == nil {
		return paycore.CredentialPayload{}, core.NewError(core.ErrCodeInvalidConfig,
			"methodDetails.planBump is required to build SubscribeData")
	}
	if details.ExpectedPeriodHours == nil {
		return paycore.CredentialPayload{}, core.NewError(core.ErrCodeInvalidConfig,
			"methodDetails.expectedPeriodHours is required to build SubscribeData")
	}
	if details.ExpectedCreatedAt == nil {
		return paycore.CredentialPayload{}, core.NewError(core.ErrCodeInvalidConfig,
			"methodDetails.expectedCreatedAt is required to build SubscribeData")
	}
	if details.Amount == "" {
		return paycore.CredentialPayload{}, core.NewError(core.ErrCodeInvalidConfig,
			"methodDetails.amount is required to build SubscribeData")
	}
	amount, err := parseAmount(details.Amount)
	if err != nil {
		return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeInvalidConfig, "parse methodDetails.amount", err)
	}

	if options.ComputeUnitLimit == 0 {
		options.ComputeUnitLimit = 400_000
	}
	if options.ComputeUnitPrice == 0 {
		options.ComputeUnitPrice = 1
	}

	instructions := make([]solana.Instruction, 0, 6)
	if ix, err := solanatx.BuildComputeUnitPrice(options.ComputeUnitPrice); err == nil {
		instructions = append(instructions, ix)
	}
	if ix, err := solanatx.BuildComputeUnitLimit(options.ComputeUnitLimit); err == nil {
		instructions = append(instructions, ix)
	}

	// ATA bootstrap. CreateIdempotent is a no-op when the ATA already exists.
	// Rent is paid by the fee payer when sponsorship is on, otherwise by the
	// subscriber.
	ataFunder := subscriber
	if details.FeePayer {
		if details.FeePayerKey == "" {
			return paycore.CredentialPayload{}, core.NewError(core.ErrCodeInvalidConfig,
				"feePayer=true requires feePayerKey in methodDetails")
		}
		ataFunder, err = subscriptions.ParsePubkey(details.FeePayerKey, "feePayerKey")
		if err != nil {
			return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeInvalidConfig, "parse feePayerKey", err)
		}
	}
	ataIx, err := solanatx.BuildCreateAssociatedTokenAccount(ataFunder, subscriber, mint, tokenProgram)
	if err != nil {
		return paycore.CredentialPayload{}, err
	}
	instructions = append(instructions, ataIx)

	// Resolve the recent blockhash. Honor the server-provided value when set so
	// the SA-init pre-step and the activation tx share the same blockhash.
	blockhash, err := solanatx.ResolveRecentBlockhash(ctx, rpcClient, details.RecentBlockhash)
	if err != nil {
		return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeRPC, "resolve recent blockhash", err)
	}

	// The on-chain Subscribe instruction binds the subscriber's signature to a
	// specific SubscriptionAuthority::init_id. The SA must exist (and we must
	// read its init_id) before signing the activation tx. When missing,
	// broadcast a one-off init tx as the subscriber.
	var expectedInitID int64
	if options.SubscriptionAuthorityInitID != nil {
		expectedInitID = *options.SubscriptionAuthorityInitID
	} else {
		expectedInitID, err = ensureSubscriptionAuthorityInitID(
			ctx, signer, rpcClient, programID, subscriber, mint, subscriberATA,
			subscriptionAuthority, tokenProgram, blockhash,
		)
		if err != nil {
			return paycore.CredentialPayload{}, err
		}
	}

	// Optional rent payer for the subscribe ix.
	var subscribePayer *solana.PublicKey
	if details.FeePayer {
		key, perr := subscriptions.ParsePubkey(details.FeePayerKey, "feePayerKey")
		if perr != nil {
			return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeInvalidConfig, "parse feePayerKey", perr)
		}
		subscribePayer = &key
	}

	instructions = append(instructions, subscriptions.BuildSubscribeIx(
		programID,
		subscriptions.SubscribeAccounts{
			Subscriber:               subscriber,
			Merchant:                 merchant,
			PlanPDA:                  planPDA,
			SubscriptionPDA:          subscriptionPDA,
			SubscriptionAuthorityPDA: subscriptionAuthority,
			EventAuthority:           eventAuthority,
			Payer:                    subscribePayer,
		},
		subscriptions.SubscribeData{
			PlanID:                            *details.PlanIDNumeric,
			PlanBump:                          *details.PlanBump,
			ExpectedMint:                      mint,
			ExpectedAmount:                    amount,
			ExpectedPeriodHours:               *details.ExpectedPeriodHours,
			ExpectedCreatedAt:                 *details.ExpectedCreatedAt,
			ExpectedSubscriptionAuthorityInit: expectedInitID,
		},
	))

	instructions = append(instructions, subscriptions.BuildTransferSubscriptionIx(
		programID,
		subscriptions.TransferSubscriptionAccounts{
			SubscriptionPDA:       subscriptionPDA,
			PlanPDA:               planPDA,
			SubscriptionAuthority: subscriptionAuthority,
			DelegatorATA:          subscriberATA,
			ReceiverATA:           recipientATA,
			Caller:                puller,
			TokenMint:             mint,
			TokenProgram:          tokenProgram,
			EventAuthority:        eventAuthority,
		},
		subscriptions.TransferData{
			Amount:    amount,
			Delegator: subscriber,
			Mint:      mint,
		},
	))

	if options.ExternalID != "" {
		memoIx, merr := solanatx.BuildMemoInstruction(options.ExternalID)
		if merr != nil {
			return paycore.CredentialPayload{}, merr
		}
		instructions = append(instructions, memoIx)
	}

	feePayerPubkey := subscriber
	if details.FeePayer {
		feePayerPubkey, err = subscriptions.ParsePubkey(details.FeePayerKey, "feePayerKey")
		if err != nil {
			return paycore.CredentialPayload{}, core.WrapError(core.ErrCodeInvalidConfig, "parse feePayerKey", err)
		}
	}

	tx, err := solana.NewTransaction(instructions, blockhash, solana.TransactionPayer(feePayerPubkey))
	if err != nil {
		return paycore.CredentialPayload{}, err
	}
	if err := solanatx.SignTransaction(tx, signer); err != nil {
		return paycore.CredentialPayload{}, err
	}

	encoded, err := solanatx.EncodeTransactionBase64(tx)
	if err != nil {
		return paycore.CredentialPayload{}, err
	}
	return paycore.CredentialPayload{Type: "transaction", Transaction: encoded}, nil
}

// BuildSubscriptionActivationHeader builds an Authorization header carrying a
// subscription activation credential from a challenge.
func BuildSubscriptionActivationHeader(
	ctx context.Context,
	signer solanatx.Signer,
	rpcClient solanatx.RPCClient,
	challenge core.PaymentChallenge,
	options SubscriptionActivationOptions,
) (string, error) {
	details, externalID, err := decodeSubscriptionChallenge(challenge)
	if err != nil {
		return "", err
	}
	if options.ExternalID == "" {
		options.ExternalID = externalID
	}
	payload, err := BuildSubscriptionActivationTransaction(ctx, signer, rpcClient, details, options)
	if err != nil {
		return "", err
	}
	credential, err := core.NewPaymentCredential(challenge.ToEcho(), payload)
	if err != nil {
		return "", err
	}
	return core.FormatAuthorization(credential)
}

func decodeSubscriptionChallenge(challenge core.PaymentChallenge) (paycore.SubscriptionMethodDetails, string, error) {
	var request struct {
		ExternalID    string `json:"externalId"`
		MethodDetails any    `json:"methodDetails"`
	}
	if err := challenge.Request.Decode(&request); err != nil {
		return paycore.SubscriptionMethodDetails{}, "", err
	}
	details, err := paycore.SubscriptionMethodDetailsFromValue(request.MethodDetails)
	if err != nil {
		return paycore.SubscriptionMethodDetails{}, "", err
	}
	return details, request.ExternalID, nil
}

// ensureSubscriptionAuthorityInitID resolves the SubscriptionAuthority::init_id
// the activation tx must reference, broadcasting a one-off subscriber-signed
// init tx when the SA PDA hasn't been created yet. The init tx is paid by the
// subscriber so the rent recipient on close is the subscriber.
func ensureSubscriptionAuthorityInitID(
	ctx context.Context,
	signer solanatx.Signer,
	rpcClient solanatx.RPCClient,
	programID, subscriber, mint, subscriberATA, subscriptionAuthority, tokenProgram solana.PublicKey,
	blockhash solana.Hash,
) (int64, error) {
	if data, err := fetchAccountData(ctx, rpcClient, subscriptionAuthority); err == nil && data != nil {
		return parseSubscriptionAuthorityInitID(data)
	}

	initIx := subscriptions.BuildInitializeSubscriptionAuthorityIx(
		programID,
		subscriptions.InitializeSubscriptionAuthorityAccounts{
			Owner:                 subscriber,
			SubscriptionAuthority: subscriptionAuthority,
			TokenMint:             mint,
			UserATA:               subscriberATA,
			TokenProgram:          tokenProgram,
		},
	)
	tx, err := solana.NewTransaction([]solana.Instruction{initIx}, blockhash, solana.TransactionPayer(subscriber))
	if err != nil {
		return 0, err
	}
	if err := solanatx.SignTransaction(tx, signer); err != nil {
		return 0, err
	}
	signature, err := solanatx.SendTransaction(ctx, rpcClient, tx)
	if err != nil {
		return 0, core.WrapError(core.ErrCodeRPC, "broadcast SubscriptionAuthority init", err)
	}
	if err := solanatx.WaitForConfirmation(ctx, rpcClient, signature); err != nil {
		return 0, core.WrapError(core.ErrCodeTransactionFailed, "confirm SubscriptionAuthority init", err)
	}
	data, err := fetchAccountData(ctx, rpcClient, subscriptionAuthority)
	if err != nil || data == nil {
		return 0, core.WrapError(core.ErrCodeRPC, "SubscriptionAuthority still missing after init broadcast", err)
	}
	return parseSubscriptionAuthorityInitID(data)
}

func fetchAccountData(ctx context.Context, rpcClient solanatx.RPCClient, account solana.PublicKey) ([]byte, error) {
	out, err := rpcClient.GetAccountInfoWithOpts(ctx, account, &rpc.GetAccountInfoOpts{
		Commitment: rpc.CommitmentConfirmed,
		Encoding:   solana.EncodingBase64,
	})
	if err != nil {
		return nil, err
	}
	if out == nil || out.Value == nil {
		return nil, fmt.Errorf("account %s not found", account)
	}
	return out.Value.Data.GetBinary(), nil
}

// parseSubscriptionAuthorityInitID extracts init_id (i64 LE) from a serialized
// SubscriptionAuthority account. init_id is the last field, at offset 98 in a
// 106-byte account.
func parseSubscriptionAuthorityInitID(data []byte) (int64, error) {
	if len(data) != subscriptionAuthorityAccountLen {
		return 0, core.NewError(core.ErrCodeInvalidPayload,
			fmt.Sprintf("unexpected SubscriptionAuthority length: got %d, expected %d",
				len(data), subscriptionAuthorityAccountLen))
	}
	raw := binary.LittleEndian.Uint64(data[subscriptionAuthorityInitIDOffset : subscriptionAuthorityInitIDOffset+8])
	return int64(raw), nil
}
