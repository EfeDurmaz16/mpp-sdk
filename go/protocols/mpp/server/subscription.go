package server

import (
	"context"
	"encoding/binary"
	"fmt"
	"os"
	"time"

	solana "github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/rpc"

	"github.com/solana-foundation/pay-kit/go/paycore"
	"github.com/solana-foundation/pay-kit/go/paycore/solanatx"
	"github.com/solana-foundation/pay-kit/go/paycore/subscriptions"
	core "github.com/solana-foundation/pay-kit/go/protocols/mpp/core"
	"github.com/solana-foundation/pay-kit/go/protocols/mpp/intents"
)

const (
	subscriptionMethodName   = "solana"
	subscriptionIntentName   = "subscription"
	defaultSubscriptionRealm = "MPP Subscription"

	// subscriptionDelegationLen is the serialized length of the on-chain
	// SubscriptionDelegation account. Mirrors #[repr(C, packed)]:
	// discriminator(1) + version(1) + bump(1) + delegator(32) + delegatee(32)
	// + payer(32) + init_id(8) + terms.amount(8) + terms.period_hours(8) +
	// terms.created_at(8) + amount_pulled(8) + period_start(8) + expires(8).
	subscriptionDelegationLen = 1 + 1 + 1 + 32 + 32 + 32 + 8 + 8 + 8 + 8 + 8 + 8 + 8
)

// SubscriptionConfig controls server-side subscription challenge generation and
// activation-credential verification. Mirrors the Rust SubscriptionConfig.
type SubscriptionConfig struct {
	// PlanID is the base58 of the on-chain Plan PDA.
	PlanID string
	// Mint is the base58 SPL token mint (must equal plan.mint).
	Mint string
	// Decimals is the decimal precision of the mint.
	Decimals uint8
	// TokenProgram is the base58 SPL Token / Token-2022 program ID.
	TokenProgram string
	// Puller is the base58 of the server's puller pubkey (plan.owner or in plan.pullers).
	Puller string
	// Recipient is the base58 of the primary recipient wallet.
	Recipient string
	// PeriodUnit is the billing period unit. The Solana profile rejects "month".
	PeriodUnit intents.SubscriptionPeriodUnit
	// PeriodCount is the positive integer count of PeriodUnit per billing period.
	PeriodCount uint64
	// SubscriptionExpires is the optional RFC3339 expiry of the recurring authorization.
	SubscriptionExpires string
	// Network is the Solana network: mainnet-beta, devnet, testnet, or localnet.
	Network string
	// ProgramID is the subscriptions program ID. Defaults to the canonical mainnet deployment.
	ProgramID string
	// RPCURL overrides the public RPC for the configured network.
	RPCURL string
	// SecretKey is the HMAC secret for challenge IDs. Defaults to MPP_SECRET_KEY env var.
	SecretKey string
	// Realm is the server realm.
	Realm string
	// FeePayer, when true, means the server pays activation transaction fees.
	FeePayer bool
	// FeePayerSigner co-signs the activation transaction when FeePayer is true.
	FeePayerSigner solanatx.Signer
	// FeePayerKey is the fee-payer pubkey emitted as methodDetails.feePayerKey.
	// When empty, falls back to FeePayerSigner's pubkey.
	FeePayerKey string
	// Store is the replay-protection store.
	Store core.Store
	// RPC is the RPC client. Defaults to a real client at the resolved RPC URL.
	RPC solanatx.RPCClient

	// PlanIDNumeric is the numeric plan_id the program reads from SubscribeData.
	PlanIDNumeric *uint64
	// PlanBump is the Plan PDA bump seed.
	PlanBump *uint8
	// PlanCreatedAt is the Plan's created_at unix timestamp, set when published on-chain.
	PlanCreatedAt *int64
}

// SubscriptionServer is the server-side handler for the Solana subscription intent.
type SubscriptionServer struct {
	config         SubscriptionConfig
	programID      string
	secretKey      string
	realm          string
	store          core.Store
	rpc            solanatx.RPCClient
	feePayerSigner solanatx.Signer
}

// NewSubscriptionServer creates a subscription handler from config. Validates
// pubkeys and period bounds eagerly so misconfigured servers fail at boot.
func NewSubscriptionServer(config SubscriptionConfig) (*SubscriptionServer, error) {
	if config.PlanID == "" {
		return nil, core.NewError(core.ErrCodeInvalidConfig, "plan_id is required")
	}
	if config.Mint == "" {
		return nil, core.NewError(core.ErrCodeInvalidConfig, "mint is required")
	}
	if config.TokenProgram == "" {
		return nil, core.NewError(core.ErrCodeInvalidConfig, "token_program is required")
	}
	if config.Puller == "" {
		return nil, core.NewError(core.ErrCodeInvalidConfig, "puller is required")
	}
	if config.Recipient == "" {
		return nil, core.NewError(core.ErrCodeInvalidConfig, "recipient is required")
	}

	for field, value := range map[string]string{
		"plan_id":       config.PlanID,
		"mint":          config.Mint,
		"token_program": config.TokenProgram,
		"puller":        config.Puller,
		"recipient":     config.Recipient,
	} {
		if _, err := subscriptions.ParsePubkey(value, field); err != nil {
			return nil, core.WrapError(core.ErrCodeInvalidConfig, "invalid "+field, err)
		}
	}

	if config.PeriodUnit == "" {
		config.PeriodUnit = intents.PeriodUnitDay
	}
	if config.PeriodCount == 0 {
		config.PeriodCount = 30
	}
	if _, err := config.PeriodUnit.ToPeriodHours(config.PeriodCount); err != nil {
		return nil, core.WrapError(core.ErrCodeInvalidConfig, "invalid period", err)
	}

	programID := config.ProgramID
	if programID == "" {
		programID = subscriptions.SubscriptionsProgramID
	}
	if _, err := subscriptions.ParsePubkey(programID, "program_id"); err != nil {
		return nil, core.WrapError(core.ErrCodeInvalidConfig, "invalid program_id", err)
	}

	if config.SecretKey == "" {
		config.SecretKey = os.Getenv(secretKeyEnvVar)
	}
	if config.SecretKey == "" {
		return nil, core.NewError(core.ErrCodeInvalidConfig, fmt.Sprintf("missing %s env var; set it or pass SecretKey explicitly", secretKeyEnvVar))
	}

	realm := config.Realm
	if realm == "" {
		realm = defaultSubscriptionRealm
	}
	if config.Decimals == 0 {
		config.Decimals = 6
	}
	if config.Network == "" {
		config.Network = "mainnet-beta"
	}
	if config.Store == nil {
		config.Store = core.NewMemoryStore()
	}
	rpcURL := config.RPCURL
	if rpcURL == "" {
		rpcURL = paycore.DefaultRPCURL(config.Network)
	}
	if config.RPC == nil {
		config.RPC = rpc.New(rpcURL)
	}

	return &SubscriptionServer{
		config:         config,
		programID:      programID,
		secretKey:      config.SecretKey,
		realm:          realm,
		store:          config.Store,
		rpc:            config.RPC,
		feePayerSigner: config.FeePayerSigner,
	}, nil
}

// SubscriptionChallenge generates a 402 subscription challenge for the
// configured amount per period (in base units).
func (s *SubscriptionServer) SubscriptionChallenge(ctx context.Context, amountBaseUnits string) (core.PaymentChallenge, error) {
	if amountBaseUnits == "" {
		return core.PaymentChallenge{}, core.NewError(core.ErrCodeInvalidPayload, "amount is required")
	}
	if _, err := (intents.SubscriptionRequest{Amount: amountBaseUnits}).ParseAmount(); err != nil {
		return core.PaymentChallenge{}, core.NewError(core.ErrCodeInvalidPayload, fmt.Sprintf("invalid amount: %s", amountBaseUnits))
	}

	feePayerKey := ""
	if s.config.FeePayer {
		feePayerKey = s.config.FeePayerKey
		if feePayerKey == "" && s.feePayerSigner != nil {
			feePayerKey = s.feePayerSigner.PublicKey().String()
		}
	}

	recentBlockhash := ""
	if out, err := s.rpc.GetLatestBlockhash(ctx, rpc.CommitmentConfirmed); err == nil && out != nil && out.Value != nil {
		recentBlockhash = out.Value.Blockhash.String()
	}

	expectedPeriodHours, _ := s.config.PeriodUnit.ToPeriodHours(s.config.PeriodCount)
	decimals := s.config.Decimals

	details := paycore.SubscriptionMethodDetails{
		PlanID:              s.config.PlanID,
		Mint:                s.config.Mint,
		TokenProgram:        s.config.TokenProgram,
		Decimals:            &decimals,
		Puller:              s.config.Puller,
		Merchant:            s.config.Puller,
		Recipient:           s.config.Recipient,
		Amount:              amountBaseUnits,
		ProgramID:           s.programID,
		Network:             s.config.Network,
		FeePayer:            s.config.FeePayer,
		FeePayerKey:         feePayerKey,
		RecentBlockhash:     recentBlockhash,
		PlanIDNumeric:       s.config.PlanIDNumeric,
		PlanBump:            s.config.PlanBump,
		ExpectedPeriodHours: &expectedPeriodHours,
		ExpectedCreatedAt:   s.config.PlanCreatedAt,
	}

	request := intents.SubscriptionRequest{
		Amount:              amountBaseUnits,
		Currency:            s.config.Mint,
		PeriodUnit:          s.config.PeriodUnit,
		PeriodCount:         fmt.Sprintf("%d", s.config.PeriodCount),
		Recipient:           s.config.Recipient,
		SubscriptionExpires: s.config.SubscriptionExpires,
		MethodDetails:       details,
	}

	encoded, err := core.NewBase64URLJSONValue(request)
	if err != nil {
		return core.PaymentChallenge{}, err
	}
	return core.NewChallengeWithSecretFull(
		s.secretKey,
		s.realm,
		core.NewMethodName(subscriptionMethodName),
		core.NewIntentName(subscriptionIntentName),
		encoded,
		core.Minutes(5),
		"",
		"",
		nil,
	), nil
}

// VerifyCredential verifies a subscription activation credential. On success it
// has broadcast the activation transaction (co-signing as fee payer when
// configured), confirmed it on-chain, and validated the resulting
// SubscriptionDelegation account against the challenge terms. Returns the base
// receipt and the subscription extensions.
func (s *SubscriptionServer) VerifyCredential(ctx context.Context, credential core.PaymentCredential) (core.Receipt, paycore.SubscriptionReceiptExtensions, error) {
	request, err := s.verifyChallengeAndDecode(credential)
	if err != nil {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, err
	}

	activate, err := decodeActivatePayload(credential)
	if err != nil {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, err
	}

	feePayerConfigured := s.config.FeePayer && s.feePayerSigner != nil
	switch activate.Type {
	case "transaction":
		if activate.Transaction == "" {
			return core.Receipt{}, paycore.SubscriptionReceiptExtensions{},
				core.NewError(core.ErrCodeMissingTransaction, `type="transaction" payload missing transaction field`)
		}
	case "signature":
		// Push-mode is defined by the spec but not yet supported in v0:
		// extracting the subscriber from a fetched versioned transaction needs
		// an account-keys reader pay-kit does not ship yet. Mirrors the Rust
		// server's v0 rejection.
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{},
			core.NewError(core.ErrCodeInvalidPayload,
				`push-mode (type="signature") activation is not yet supported by this server; use type="transaction"`)
	default:
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{},
			core.NewError(core.ErrCodeInvalidPayload, fmt.Sprintf("unsupported payload type %q (expected transaction or signature)", activate.Type))
	}

	if activate.Type == "signature" && feePayerConfigured {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{},
			core.NewError(core.ErrCodeInvalidPayload, `type="signature" credentials cannot be used with fee sponsorship`)
	}

	tx, err := solanatx.DecodeTransactionBase64(activate.Transaction)
	if err != nil {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, err
	}

	if err := validateActivationScope(tx, s.programID); err != nil {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, err
	}

	subscriber, err := extractSubscriberFromTx(tx, s.config, s.feePayerSigner)
	if err != nil {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, err
	}

	if feePayerConfigured {
		if err := solanatx.SignTransaction(tx, s.feePayerSigner); err != nil {
			return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, err
		}
	}

	programID, err := subscriptions.ParsePubkey(s.programID, "program_id")
	if err != nil {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, err
	}
	planPDA, err := subscriptions.ParsePubkey(s.config.PlanID, "plan_id")
	if err != nil {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, err
	}
	subscriptionPDA, _, err := subscriptions.FindSubscriptionPDA(planPDA, subscriber, programID)
	if err != nil {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, err
	}

	// Idempotent broadcast: if the delegation PDA already exists (a previous
	// activation landed but the receipt round-trip failed), skip the broadcast.
	// The on-chain Subscribe would otherwise reject with AlreadySubscribed and
	// bury the actual outcome. The subsequent fetch + terms check catches any
	// divergence.
	activationSignature := ""
	if existing, _ := s.fetchSubscriptionDelegation(ctx, subscriptionPDA); existing == nil {
		if err := solanatx.SimulateTransaction(ctx, s.rpc, tx); err != nil {
			return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, core.WrapError(core.ErrCodeSimulationFailed, "simulate activation", err)
		}
		signature, err := solanatx.SendTransaction(ctx, s.rpc, tx)
		if err != nil {
			return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, core.WrapError(core.ErrCodeRPC, "broadcast activation", err)
		}
		if err := solanatx.WaitForConfirmation(ctx, s.rpc, signature); err != nil {
			return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, core.WrapError(core.ErrCodeTransactionFailed, "confirm activation", err)
		}
		activationSignature = signature.String()
	}

	delegation, err := s.fetchSubscriptionDelegation(ctx, subscriptionPDA)
	if err != nil || delegation == nil {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{},
			core.WrapError(core.ErrCodeTransactionNotFound, "SubscriptionDelegation account not found", err)
	}

	expectedAmount, err := request.ParseAmount()
	if err != nil {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, core.NewError(core.ErrCodeInvalidPayload, err.Error())
	}
	expectedPeriodHours, err := request.PeriodHours()
	if err != nil {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{}, core.NewError(core.ErrCodeInvalidPayload, err.Error())
	}

	if delegation.AmountPerPeriod != expectedAmount {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{},
			core.NewError(core.ErrCodeAmountMismatch, fmt.Sprintf("SubscriptionDelegation amount mismatch: expected %d, got %d", expectedAmount, delegation.AmountPerPeriod))
	}
	if delegation.PeriodHours != expectedPeriodHours {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{},
			core.NewError(core.ErrCodeChallengeRouteMismatch, fmt.Sprintf("SubscriptionDelegation period mismatch: expected %dh, got %dh", expectedPeriodHours, delegation.PeriodHours))
	}
	if !delegation.PlanPDA.Equals(planPDA) {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{},
			core.NewError(core.ErrCodeChallengeRouteMismatch, fmt.Sprintf("SubscriptionDelegation plan mismatch: expected %s, got %s", planPDA, delegation.PlanPDA))
	}
	if delegation.AmountPulledInPeriod != expectedAmount {
		return core.Receipt{}, paycore.SubscriptionReceiptExtensions{},
			core.NewError(core.ErrCodeNoTransfer, "activation transaction did not execute the first-period charge")
	}

	periodStart := delegation.CurrentPeriodStartTS
	periodEnd := periodStart + int64(expectedPeriodHours)*3600

	receipt := core.Receipt{
		Status:      core.ReceiptStatusSuccess,
		Method:      core.NewMethodName(subscriptionMethodName),
		Timestamp:   time.Now().UTC().Format(time.RFC3339),
		Reference:   subscriptionPDA.String(),
		ChallengeID: credential.Challenge.ID,
		ExternalID:  request.ExternalID,
	}
	extensions := paycore.SubscriptionReceiptExtensions{
		SubscriptionID:      subscriptionPDA.String(),
		PlanID:              s.config.PlanID,
		PeriodIndex:         "0",
		PeriodStartTs:       formatRFC3339Seconds(periodStart),
		PeriodEndTs:         formatRFC3339Seconds(periodEnd),
		ExpiresAt:           request.SubscriptionExpires,
		ActivationSignature: activationSignature,
	}
	return receipt, extensions, nil
}

func (s *SubscriptionServer) verifyChallengeAndDecode(credential core.PaymentCredential) (intents.SubscriptionRequest, error) {
	challenge := core.PaymentChallenge{
		ID:      credential.Challenge.ID,
		Realm:   credential.Challenge.Realm,
		Method:  credential.Challenge.Method,
		Intent:  credential.Challenge.Intent,
		Request: credential.Challenge.Request,
		Expires: credential.Challenge.Expires,
		Digest:  credential.Challenge.Digest,
		Opaque:  credential.Challenge.Opaque,
	}
	if !challenge.Verify(s.secretKey) {
		return intents.SubscriptionRequest{}, core.NewError(core.ErrCodeChallengeMismatch,
			"challenge HMAC mismatch: this server did not issue the echoed challenge")
	}
	if challenge.IsExpired(time.Now()) {
		return intents.SubscriptionRequest{}, core.NewError(core.ErrCodeChallengeExpired,
			fmt.Sprintf("challenge expired at %s", challenge.Expires))
	}
	if string(credential.Challenge.Method) != subscriptionMethodName {
		return intents.SubscriptionRequest{}, core.NewError(core.ErrCodeChallengeRouteMismatch,
			fmt.Sprintf("credential method %q does not match this server (expected %q)", credential.Challenge.Method, subscriptionMethodName))
	}
	if !credential.Challenge.Intent.IsSubscription() {
		return intents.SubscriptionRequest{}, core.NewError(core.ErrCodeChallengeRouteMismatch,
			fmt.Sprintf("credential intent %q is not a subscription", credential.Challenge.Intent))
	}
	if credential.Challenge.Realm != s.realm {
		return intents.SubscriptionRequest{}, core.NewError(core.ErrCodeChallengeRouteMismatch,
			fmt.Sprintf("credential realm %q does not match this server (expected %q)", credential.Challenge.Realm, s.realm))
	}
	var request intents.SubscriptionRequest
	if err := challenge.Request.Decode(&request); err != nil {
		return intents.SubscriptionRequest{}, err
	}
	if request.Currency != s.config.Mint {
		return intents.SubscriptionRequest{}, core.NewError(core.ErrCodeMintMismatch,
			fmt.Sprintf("credential mint %q does not match this server (expected %q)", request.Currency, s.config.Mint))
	}
	if request.Recipient != s.config.Recipient {
		return intents.SubscriptionRequest{}, core.NewError(core.ErrCodeRecipientMismatch,
			"credential recipient does not match this server")
	}
	return request, nil
}

// Accessors expose config values for callers and tests.

// Realm returns the server realm.
func (s *SubscriptionServer) Realm() string { return s.realm }

// PlanID returns the configured Plan PDA base58.
func (s *SubscriptionServer) PlanID() string { return s.config.PlanID }

// Mint returns the configured mint base58.
func (s *SubscriptionServer) Mint() string { return s.config.Mint }

// Recipient returns the configured recipient base58.
func (s *SubscriptionServer) Recipient() string { return s.config.Recipient }

// Puller returns the configured puller base58.
func (s *SubscriptionServer) Puller() string { return s.config.Puller }

// ProgramID returns the resolved subscriptions program ID base58.
func (s *SubscriptionServer) ProgramID() string { return s.programID }

// PeriodUnit returns the configured billing period unit.
func (s *SubscriptionServer) PeriodUnit() intents.SubscriptionPeriodUnit { return s.config.PeriodUnit }

// PeriodCount returns the configured billing period count.
func (s *SubscriptionServer) PeriodCount() uint64 { return s.config.PeriodCount }

func (s *SubscriptionServer) fetchSubscriptionDelegation(ctx context.Context, pda solana.PublicKey) (*subscriptionDelegationView, error) {
	out, err := s.rpc.GetAccountInfoWithOpts(ctx, pda, &rpc.GetAccountInfoOpts{
		Commitment: rpc.CommitmentConfirmed,
		Encoding:   solana.EncodingBase64,
	})
	if err != nil {
		return nil, err
	}
	if out == nil || out.Value == nil {
		return nil, fmt.Errorf("SubscriptionDelegation account %s not found", pda)
	}
	return decodeSubscriptionDelegation(out.Value.Data.GetBinary())
}

// ── Verify helpers (pure, golden-vector testable) ────────────────────────

// decodeActivatePayload plucks the ActivatePayload from a credential's payload,
// accepting both the raw ActivatePayload shape (the v0 spec) and the tagged
// SubscriptionAction wrapper.
func decodeActivatePayload(credential core.PaymentCredential) (paycore.ActivatePayload, error) {
	var action paycore.SubscriptionAction
	if err := credential.PayloadAs(&action); err == nil && action.Action == "activate" {
		return paycore.ActivatePayload{
			Type:        action.Type,
			Transaction: action.Transaction,
			Signature:   action.Signature,
		}, nil
	}
	var payload paycore.ActivatePayload
	if err := credential.PayloadAs(&payload); err != nil {
		return paycore.ActivatePayload{}, core.WrapError(core.ErrCodeInvalidPayload, "decode activation payload", err)
	}
	if payload.Type == "" {
		return paycore.ActivatePayload{}, core.NewError(core.ErrCodeInvalidPayload, "activation payload missing type")
	}
	return payload, nil
}

// validateActivationScope requires exactly one Subscribe instruction and
// exactly one TransferSubscription instruction on the configured subscriptions
// program, with Subscribe ordered before TransferSubscription.
func validateActivationScope(tx *solana.Transaction, programIDStr string) error {
	programID, err := subscriptions.ParsePubkey(programIDStr, "program_id")
	if err != nil {
		return err
	}
	subscribeIdx := -1
	transferIdx := -1
	for i, ix := range tx.Message.Instructions {
		programKey, err := resolveProgramID(tx, ix.ProgramIDIndex)
		if err != nil {
			return err
		}
		if !programKey.Equals(programID) {
			continue
		}
		data := []byte(ix.Data)
		if len(data) == 0 {
			continue
		}
		switch data[0] {
		case subscriptions.InstructionSubscribe:
			if subscribeIdx >= 0 {
				return core.NewError(core.ErrCodeInvalidPayload, "activation tx contains multiple subscribe instructions")
			}
			subscribeIdx = i
		case subscriptions.InstructionTransferSubscription:
			if transferIdx >= 0 {
				return core.NewError(core.ErrCodeInvalidPayload, "activation tx contains multiple transfer_subscription instructions")
			}
			transferIdx = i
		}
	}
	if subscribeIdx < 0 {
		return core.NewError(core.ErrCodeInvalidPayload, "activation tx is missing subscribe instruction")
	}
	if transferIdx < 0 {
		return core.NewError(core.ErrCodeInvalidPayload, "activation tx is missing transfer_subscription instruction")
	}
	if transferIdx < subscribeIdx {
		return core.NewError(core.ErrCodeInvalidPayload, "subscribe must precede transfer_subscription in activation tx")
	}
	return nil
}

// extractSubscriberFromTx extracts the subscriber pubkey from the activation
// transaction. With fee sponsorship the fee payer is the first signer (the
// server); the subscriber is the next signer that isn't the puller. Otherwise
// the subscriber is account_keys[0].
func extractSubscriberFromTx(tx *solana.Transaction, config SubscriptionConfig, feePayerSigner solanatx.Signer) (solana.PublicKey, error) {
	keys := tx.Message.AccountKeys
	if len(keys) == 0 {
		return solana.PublicKey{}, core.NewError(core.ErrCodeInvalidPayload, "transaction has no account keys")
	}
	puller, err := subscriptions.ParsePubkey(config.Puller, "puller")
	if err != nil {
		return solana.PublicKey{}, err
	}

	if config.FeePayer {
		feePayerKeyStr := config.FeePayerKey
		if feePayerKeyStr == "" && feePayerSigner != nil {
			feePayerKeyStr = feePayerSigner.PublicKey().String()
		}
		if feePayerKeyStr != "" {
			feePayer, perr := subscriptions.ParsePubkey(feePayerKeyStr, "fee_payer_key")
			if perr != nil {
				return solana.PublicKey{}, perr
			}
			for _, k := range keys[1:] {
				if !k.Equals(puller) && !k.Equals(feePayer) {
					return k, nil
				}
			}
			return solana.PublicKey{}, core.NewError(core.ErrCodeInvalidPayload, "could not identify subscriber among transaction signers")
		}
	}

	first := keys[0]
	if first.Equals(puller) {
		return solana.PublicKey{}, core.NewError(core.ErrCodeInvalidPayload, "subscriber cannot equal the server puller")
	}
	return first, nil
}

// subscriptionDelegationView is the minimal in-process view of the on-chain
// SubscriptionDelegation account that verify needs. Mirrors the #[repr(C, packed)]
// layout offsets documented in rust/src/server/subscription.rs.
type subscriptionDelegationView struct {
	Subscriber           solana.PublicKey
	PlanPDA              solana.PublicKey
	AmountPerPeriod      uint64
	PeriodHours          uint64
	CurrentPeriodStartTS int64
	AmountPulledInPeriod uint64
}

func decodeSubscriptionDelegation(data []byte) (*subscriptionDelegationView, error) {
	if len(data) < subscriptionDelegationLen {
		return nil, core.NewError(core.ErrCodeInvalidPayload,
			fmt.Sprintf("SubscriptionDelegation account too short: %d bytes (need >= %d)", len(data), subscriptionDelegationLen))
	}
	// header.discriminator(1) + version(1) + bump(1) = 3 bytes before delegator.
	off := 3
	var subscriber solana.PublicKey
	copy(subscriber[:], data[off:off+32])
	off += 32
	var planPDA solana.PublicKey
	copy(planPDA[:], data[off:off+32])
	off += 32
	off += 32 // payer
	off += 8  // init_id
	amountPerPeriod := binary.LittleEndian.Uint64(data[off : off+8])
	off += 8
	periodHours := binary.LittleEndian.Uint64(data[off : off+8])
	off += 8
	off += 8 // terms.created_at, unused by the verifier
	amountPulledInPeriod := binary.LittleEndian.Uint64(data[off : off+8])
	off += 8
	currentPeriodStartTS := int64(binary.LittleEndian.Uint64(data[off : off+8]))

	return &subscriptionDelegationView{
		Subscriber:           subscriber,
		PlanPDA:              planPDA,
		AmountPerPeriod:      amountPerPeriod,
		PeriodHours:          periodHours,
		CurrentPeriodStartTS: currentPeriodStartTS,
		AmountPulledInPeriod: amountPulledInPeriod,
	}, nil
}

// formatRFC3339Seconds formats a unix-seconds timestamp as RFC 3339 in UTC.
func formatRFC3339Seconds(secs int64) string {
	return time.Unix(secs, 0).UTC().Format(time.RFC3339)
}
