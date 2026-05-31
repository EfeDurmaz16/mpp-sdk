package intents

import (
	"encoding/json"
	"testing"
)

func TestParseOptionalU64Variants(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		wantNil bool
		wantVal uint64
		wantErr bool
	}{
		{name: "empty", raw: "", wantNil: true},
		{name: "null", raw: "null", wantNil: true},
		{name: "number", raw: "42", wantVal: 42},
		{name: "string", raw: `"77"`, wantVal: 77},
		{name: "bad string", raw: `"abc"`, wantErr: true},
		{name: "bad number", raw: "-1", wantErr: true},
		{name: "malformed string", raw: `"`, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseOptionalU64(json.RawMessage(tc.raw))
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error for %q", tc.raw)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if tc.wantNil {
				if got != nil {
					t.Fatalf("expected nil, got %d", *got)
				}
				return
			}
			if got == nil || *got != tc.wantVal {
				t.Fatalf("got %v, want %d", got, tc.wantVal)
			}
		})
	}
}

func TestOpenPayloadUnmarshalRejectsBadSalt(t *testing.T) {
	if err := json.Unmarshal([]byte(`{"mode":"push","salt":"notanumber"}`), &OpenPayload{}); err == nil {
		t.Fatalf("expected bad salt rejection")
	}
	if err := json.Unmarshal([]byte(`{"mode":"push"`), &OpenPayload{}); err == nil {
		t.Fatalf("expected malformed JSON rejection")
	}
}

func TestOpenPayloadMarshalEmitsSaltString(t *testing.T) {
	salt := uint64(9007199254740993) // beyond JS safe integer
	p := OpenPayload{Mode: SessionModePush, ChannelID: "c", Salt: &salt}
	raw, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	var back OpenPayload
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if back.Salt == nil || *back.Salt != salt {
		t.Fatalf("salt roundtrip mismatch: %v", back.Salt)
	}
}

func TestOpenPayloadSessionIDErrors(t *testing.T) {
	if _, err := (OpenPayload{Mode: SessionModePush}).SessionID(); err == nil {
		t.Fatalf("push without channelId should error")
	}
	if _, err := (OpenPayload{Mode: SessionModePull}).SessionID(); err == nil {
		t.Fatalf("pull without channelId/tokenAccount should error")
	}
	id, err := (OpenPayload{Mode: SessionModePull, TokenAccount: "ta"}).SessionID()
	if err != nil || id != "ta" {
		t.Fatalf("pull tokenAccount sessionID mismatch: %s %v", id, err)
	}
	if _, err := (OpenPayload{Mode: SessionMode("weird")}).SessionID(); err == nil {
		t.Fatalf("unknown mode should error")
	}
}

func TestOpenPayloadDepositAmountBranches(t *testing.T) {
	if _, err := (OpenPayload{Mode: SessionModePush}).DepositAmount(); err == nil {
		t.Fatalf("push without deposit should error")
	}
	if _, err := (OpenPayload{Mode: SessionModePull}).DepositAmount(); err == nil {
		t.Fatalf("pull without approvedAmount should error")
	}
	if _, err := (OpenPayload{Mode: SessionMode("weird")}).DepositAmount(); err == nil {
		t.Fatalf("unknown mode should error")
	}
	v, err := (OpenPayload{Mode: SessionModePull, ApprovedAmount: "500"}).DepositAmount()
	if err != nil || v != 500 {
		t.Fatalf("pull approvedAmount mismatch: %d %v", v, err)
	}
}

func TestVoucherDataMessageBytesErrors(t *testing.T) {
	if _, err := (VoucherData{ChannelID: "!!notbase58", Cumulative: "1"}).MessageBytes(); err == nil {
		t.Fatalf("expected invalid channelId error")
	}
	if _, err := (VoucherData{ChannelID: "11111111111111111111111111111111", Cumulative: "x"}).MessageBytes(); err == nil {
		t.Fatalf("expected invalid cumulative error")
	}
}

func TestVoucherDataMarshalRoundtripWithNonce(t *testing.T) {
	nonce := uint64(3)
	v := VoucherData{ChannelID: "11111111111111111111111111111111", Cumulative: "10", ExpiresAt: 99, Nonce: &nonce}
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var back VoucherData
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if back.Cumulative != "10" || back.ExpiresAt != 99 || back.Nonce == nil || *back.Nonce != 3 {
		t.Fatalf("voucher roundtrip mismatch: %+v", back)
	}
}

func TestSessionActionMarshalErrors(t *testing.T) {
	if _, err := json.Marshal(SessionAction{Action: SessionActionTag("bogus")}); err == nil {
		t.Fatalf("unknown action tag should error on marshal")
	}
}

func TestSessionActionUnmarshalAllVariants(t *testing.T) {
	cases := map[string]func(SessionAction) bool{
		`{"action":"voucher","voucher":{"data":{"channelId":"c","cumulativeAmount":"1","expiresAt":1},"signature":"s"}}`:                 func(a SessionAction) bool { return a.Voucher != nil },
		`{"action":"commit","deliveryId":"d","voucher":{"data":{"channelId":"c","cumulativeAmount":"1","expiresAt":1},"signature":"s"}}`: func(a SessionAction) bool { return a.Commit != nil },
		`{"action":"topUp","channelId":"c","newDeposit":"5","signature":"t"}`:                                                            func(a SessionAction) bool { return a.TopUp != nil },
		`{"action":"close","channelId":"c"}`: func(a SessionAction) bool { return a.Close != nil },
	}
	for raw, check := range cases {
		var a SessionAction
		if err := json.Unmarshal([]byte(raw), &a); err != nil {
			t.Fatalf("unmarshal %s: %v", raw, err)
		}
		if !check(a) {
			t.Fatalf("variant not populated for %s", raw)
		}
	}
}

func TestSessionActionUnmarshalErrors(t *testing.T) {
	if err := json.Unmarshal([]byte(`{`), &SessionAction{}); err == nil {
		t.Fatalf("malformed JSON should error")
	}
	if err := json.Unmarshal([]byte(`{"action":"bogus"}`), &SessionAction{}); err == nil {
		t.Fatalf("unknown action tag should error")
	}
	badPayloads := []string{
		`{"action":"open","salt":"bad"}`,
		`{"action":"voucher","voucher":123}`,
		`{"action":"commit","voucher":123}`,
		`{"action":"topUp","channelId":123}`,
		`{"action":"close","voucher":123}`,
	}
	for _, raw := range badPayloads {
		if err := json.Unmarshal([]byte(raw), &SessionAction{}); err == nil {
			t.Fatalf("expected payload decode error for %s", raw)
		}
	}
}

func TestSessionActionMarshalCommitTopUpClose(t *testing.T) {
	voucher := SignedVoucher{Data: VoucherData{ChannelID: "c", Cumulative: "10", ExpiresAt: 1}, Signature: "s"}
	cases := []struct {
		name   string
		action SessionAction
		tag    string
	}{
		{"commit", SessionAction{Action: ActionCommit, Commit: &CommitPayload{DeliveryID: "d", Voucher: voucher}}, "commit"},
		{"topUp", SessionAction{Action: ActionTopUp, TopUp: &TopUpPayload{ChannelID: "c", NewDeposit: "5", Signature: "t"}}, "topUp"},
		{"close", SessionAction{Action: ActionClose, Close: &ClosePayload{ChannelID: "c", Voucher: &voucher}}, "close"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			raw, err := json.Marshal(tc.action)
			if err != nil {
				t.Fatal(err)
			}
			var back SessionAction
			if err := json.Unmarshal(raw, &back); err != nil {
				t.Fatal(err)
			}
			if string(back.Action) != tc.tag {
				t.Fatalf("action tag = %s, want %s", back.Action, tc.tag)
			}
		})
	}
}

func TestMeteringUsageAndDirectiveBadAmounts(t *testing.T) {
	if _, err := (MeteringDirective{Amount: "x"}).AmountBaseUnits(); err == nil {
		t.Fatalf("bad directive amount should error")
	}
	if _, err := (MeteringUsage{Amount: "x"}).AmountBaseUnits(); err == nil {
		t.Fatalf("bad usage amount should error")
	}
}
