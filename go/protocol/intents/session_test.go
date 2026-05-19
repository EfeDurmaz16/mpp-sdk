package intents

import (
	"encoding/json"
	"testing"
)

func TestSessionRequestRoundTripsSharedWireFields(t *testing.T) {
	decimals := uint8(6)
	strategy := SessionPullVoucherStrategyClientVoucher
	request := SessionRequest{
		Cap:                 "1000000",
		Currency:            "USDC",
		Decimals:            &decimals,
		Network:             "devnet",
		Operator:            "operator",
		Recipient:           "recipient",
		Splits:              []SessionSplit{{Recipient: "affiliate", BPS: 250}},
		ProgramID:           "program",
		Description:         "Metered API session",
		ExternalID:          "session-001",
		MinVoucherDelta:     "1000",
		Modes:               []SessionMode{SessionModePush, SessionModePull},
		PullVoucherStrategy: &strategy,
		RecentBlockhash:     "blockhash",
	}

	if err := request.Validate(); err != nil {
		t.Fatalf("request should validate: %v", err)
	}

	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	var decoded SessionRequest
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if decoded.ProgramID != "program" || decoded.ExternalID != "session-001" {
		t.Fatalf("decoded request lost fields: %#v", decoded)
	}
	if decoded.PullVoucherStrategy == nil || *decoded.PullVoucherStrategy != strategy {
		t.Fatalf("unexpected pull voucher strategy: %#v", decoded.PullVoucherStrategy)
	}
}

func TestSessionRequestRequiresPullStrategyWhenPullModeIsAdvertised(t *testing.T) {
	request := SessionRequest{
		Cap:       "1000000",
		Currency:  "USDC",
		Operator:  "operator",
		Recipient: "recipient",
		Modes:     []SessionMode{SessionModePull},
	}

	if err := request.Validate(); err == nil {
		t.Fatal("expected pullVoucherStrategy validation error")
	}
}

func TestOpenPayloadValidatesModeSpecificFields(t *testing.T) {
	push := OpenPayload{
		Action:           "open",
		Mode:             SessionModePush,
		ChannelID:        "channel",
		Deposit:          "1000000",
		AuthorizedSigner: "session-signer",
		Signature:        "signature",
	}
	if err := push.Validate(); err != nil {
		t.Fatalf("push open should validate: %v", err)
	}

	pull := OpenPayload{
		Action:           "open",
		Mode:             SessionModePull,
		TokenAccount:     "token-account",
		ApprovedAmount:   "1000000",
		AuthorizedSigner: "session-signer",
		Signature:        "signature",
	}
	if err := pull.Validate(); err != nil {
		t.Fatalf("pull open should validate: %v", err)
	}
}

func TestSignedVoucherAcceptsCumulativeAlias(t *testing.T) {
	var voucher SignedVoucher
	err := json.Unmarshal([]byte(`{
		"data": {
			"channelId": "channel",
			"cumulative": "25000",
			"expiresAt": 4102444800
		},
		"signature": "signature"
	}`), &voucher)
	if err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if err := voucher.Validate(); err != nil {
		t.Fatalf("voucher should validate: %v", err)
	}
	if voucher.Data.CumulativeAmount != "25000" {
		t.Fatalf("expected cumulative alias, got %q", voucher.Data.CumulativeAmount)
	}
}

func TestMeteringDirectiveAndCommitReceiptValidateWireFields(t *testing.T) {
	directive := MeteringDirective{
		DeliveryID: "delivery-001",
		SessionID:  "channel",
		Amount:     "5000",
		Currency:   "USDC",
		Sequence:   1,
		ExpiresAt:  DefaultSessionExpiresAt,
		CommitURL:  "https://merchant.example/session/commit",
		Proof:      "proof",
	}
	if err := directive.Validate(); err != nil {
		t.Fatalf("directive should validate: %v", err)
	}

	receipt := CommitReceipt{
		DeliveryID: "delivery-001",
		SessionID:  "channel",
		Amount:     "5000",
		Cumulative: "30000",
		Status:     CommitStatusCommitted,
	}
	if err := receipt.Validate(); err != nil {
		t.Fatalf("receipt should validate: %v", err)
	}
}

func TestCommitReceiptRejectsUnknownStatus(t *testing.T) {
	receipt := CommitReceipt{
		DeliveryID: "delivery-001",
		SessionID:  "channel",
		Amount:     "5000",
		Cumulative: "30000",
		Status:     CommitStatus("accepted"),
	}

	if err := receipt.Validate(); err == nil {
		t.Fatal("expected status validation error")
	}
}
