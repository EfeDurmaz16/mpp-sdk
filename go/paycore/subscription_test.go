package paycore

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSubscriptionMethodDetailsFromValueRequiredFields(t *testing.T) {
	value := map[string]any{
		"planId":       "8tWbqLkUJoYy7zXc5h2EvCRoaQEv2xnQjUuYhc3rzCgT",
		"mint":         "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
		"tokenProgram": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
		"puller":       "5fKb5cF22cFybZB1H4hLDydFhwoQy9JzKzRWaSbMkB6h",
		"feePayer":     true,
		"feePayerKey":  "5fKb5cF22cFybZB1H4hLDydFhwoQy9JzKzRWaSbMkB6h",
	}
	md, err := SubscriptionMethodDetailsFromValue(value)
	if err != nil {
		t.Fatal(err)
	}
	if !md.FeePayer {
		t.Error("feePayer should decode true")
	}
	if md.PlanID != "8tWbqLkUJoYy7zXc5h2EvCRoaQEv2xnQjUuYhc3rzCgT" {
		t.Errorf("planId = %s", md.PlanID)
	}
	if err := md.Validate(); err != nil {
		t.Errorf("Validate: %v", err)
	}
}

func TestSubscriptionMethodDetailsValidateRejectsMissing(t *testing.T) {
	cases := map[string]SubscriptionMethodDetails{
		"planId":       {Mint: "m", TokenProgram: "t", Puller: "p"},
		"mint":         {PlanID: "p", TokenProgram: "t", Puller: "p"},
		"tokenProgram": {PlanID: "p", Mint: "m", Puller: "p"},
		"puller":       {PlanID: "p", Mint: "m", TokenProgram: "t"},
	}
	for field, md := range cases {
		err := md.Validate()
		if err == nil || !strings.Contains(err.Error(), field) {
			t.Errorf("missing %s: got err = %v", field, err)
		}
	}
}

func TestSubscriptionMethodDetailsFeePayerKeyRequired(t *testing.T) {
	md := SubscriptionMethodDetails{PlanID: "p", Mint: "m", TokenProgram: "t", Puller: "p", FeePayer: true}
	if err := md.Validate(); err == nil || !strings.Contains(err.Error(), "feePayerKey") {
		t.Errorf("feePayer without key: got err = %v", err)
	}
}

func TestSubscriptionMethodDetailsSerializesCamelCase(t *testing.T) {
	dec := uint8(6)
	num := uint64(1)
	bump := uint8(255)
	hours := uint64(720)
	created := int64(1_700_000_000)
	md := SubscriptionMethodDetails{
		PlanID:              "plan",
		Mint:                "mint",
		TokenProgram:        "tp",
		Decimals:            &dec,
		Puller:              "puller",
		Amount:              "10000000",
		PlanIDNumeric:       &num,
		PlanBump:            &bump,
		ExpectedPeriodHours: &hours,
		ExpectedCreatedAt:   &created,
	}
	raw, err := json.Marshal(md)
	if err != nil {
		t.Fatal(err)
	}
	out := string(raw)
	for _, want := range []string{
		`"planId":"plan"`, `"tokenProgram":"tp"`, `"planIdNumeric":1`,
		`"planBump":255`, `"expectedPeriodHours":720`, `"expectedCreatedAt":1700000000`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s in %s", want, out)
		}
	}
}

func TestSubscriptionMethodDetailsOmitsOptionalWhenAbsent(t *testing.T) {
	md := SubscriptionMethodDetails{PlanID: "p", Mint: "m", TokenProgram: "t", Puller: "p"}
	raw, _ := json.Marshal(md)
	out := string(raw)
	for _, absent := range []string{"decimals", "planIdNumeric", "feePayerKey", "recentBlockhash"} {
		if strings.Contains(out, absent) {
			t.Errorf("did not expect %s in %s", absent, out)
		}
	}
}

func TestActivatePayloadRoundTrip(t *testing.T) {
	p := ActivatePayload{Type: "transaction", Transaction: "AQAAAA=="}
	raw, _ := json.Marshal(p)
	out := string(raw)
	if !strings.Contains(out, `"type":"transaction"`) || strings.Contains(out, `"signature"`) {
		t.Errorf("unexpected serialization %s", out)
	}
	var back ActivatePayload
	if err := json.Unmarshal(raw, &back); err != nil || back.Type != "transaction" {
		t.Fatalf("round-trip failed: %v %+v", err, back)
	}
}

func TestSubscriptionActionTaggedShape(t *testing.T) {
	action := SubscriptionAction{Action: "activate", Type: "transaction", Transaction: "AQAAAA=="}
	raw, _ := json.Marshal(action)
	if !strings.Contains(string(raw), `"action":"activate"`) {
		t.Errorf("missing action tag: %s", raw)
	}
}

func TestSubscriptionReceiptExtensionsSerialize(t *testing.T) {
	ext := SubscriptionReceiptExtensions{
		SubscriptionID: "BXQGmO5VwTrl5RfFr6Y8XQZ4nPj9QqMOiKkRn3pZ4ZE",
		PlanID:         "8tWbqLkUJoYy7zXc5h2EvCRoaQEv2xnQjUuYhc3rzCgT",
		PeriodIndex:    "0",
		PeriodStartTs:  "2026-01-15T12:03:10Z",
		PeriodEndTs:    "2026-02-14T12:03:10Z",
		ExpiresAt:      "2026-07-14T12:00:00Z",
	}
	raw, _ := json.Marshal(ext)
	out := string(raw)
	for _, want := range []string{
		`"subscriptionId"`, `"planId"`, `"periodIndex":"0"`,
		`"periodStartTs"`, `"periodEndTs"`, `"expiresAt"`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s in %s", want, out)
		}
	}
}

func TestSubscriptionReceiptExtensionsOmitsExpiresWhenEmpty(t *testing.T) {
	ext := SubscriptionReceiptExtensions{SubscriptionID: "s", PlanID: "p", PeriodIndex: "0"}
	raw, _ := json.Marshal(ext)
	if strings.Contains(string(raw), "expiresAt") || strings.Contains(string(raw), "activationSignature") {
		t.Errorf("optional fields should be omitted: %s", raw)
	}
}
