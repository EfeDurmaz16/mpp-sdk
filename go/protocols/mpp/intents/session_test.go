package intents

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSessionModeSerialization(t *testing.T) {
	raw, _ := json.Marshal(SessionModePush)
	if string(raw) != `"push"` {
		t.Fatalf("push = %s", raw)
	}
	raw, _ = json.Marshal(SessionModePull)
	if string(raw) != `"pull"` {
		t.Fatalf("pull = %s", raw)
	}
}

func TestSessionPullVoucherStrategyRoundtrip(t *testing.T) {
	raw, _ := json.Marshal(PullStrategyClientVoucher)
	if string(raw) != `"clientVoucher"` {
		t.Fatalf("clientVoucher = %s", raw)
	}
	raw, _ = json.Marshal(PullStrategyOperatedVoucher)
	if string(raw) != `"operatedVoucher"` {
		t.Fatalf("operatedVoucher = %s", raw)
	}
}

func TestSessionRequestOmitsEmptyFields(t *testing.T) {
	req := SessionRequest{Cap: "1000", Currency: "USDC", Operator: "op", Recipient: "rec"}
	raw, _ := json.Marshal(req)
	s := string(raw)
	for _, field := range []string{"splits", "modes", "decimals", "network", "description", "externalId", "minVoucherDelta", "pullVoucherStrategy"} {
		if strings.Contains(s, field) {
			t.Fatalf("expected %q omitted, got %s", field, s)
		}
	}
}

func TestSessionRequestModesAndStrategy(t *testing.T) {
	strategy := PullStrategyClientVoucher
	req := SessionRequest{
		Cap: "1000", Currency: "USDC", Operator: "op", Recipient: "rec",
		Modes:               []SessionMode{SessionModePush, SessionModePull},
		PullVoucherStrategy: &strategy,
	}
	raw, _ := json.Marshal(req)
	s := string(raw)
	if !strings.Contains(s, `"pullVoucherStrategy":"clientVoucher"`) {
		t.Fatalf("missing pullVoucherStrategy: %s", s)
	}
	var back SessionRequest
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if len(back.Modes) != 2 || back.Modes[0] != SessionModePush || back.Modes[1] != SessionModePull {
		t.Fatalf("modes roundtrip mismatch: %v", back.Modes)
	}
}

func TestOpenPayloadPushFields(t *testing.T) {
	p := NewOpenPush("chan1", "1000000", "signer1", "txsig")
	if p.Mode != SessionModePush || p.ChannelID != "chan1" || p.Deposit != "1000000" {
		t.Fatalf("push fields mismatch: %+v", p)
	}
	id, err := p.SessionID()
	if err != nil || id != "chan1" {
		t.Fatalf("session id = %q err=%v", id, err)
	}
	dep, err := p.DepositAmount()
	if err != nil || dep != 1_000_000 {
		t.Fatalf("deposit = %d err=%v", dep, err)
	}
}

func TestOpenPayloadPullFields(t *testing.T) {
	p := NewOpenPull("tokacct", "5000000", "wallet1", "signer1", "approvesig")
	if p.Mode != SessionModePull || p.TokenAccount != "tokacct" || p.Owner != "wallet1" {
		t.Fatalf("pull fields mismatch: %+v", p)
	}
	id, _ := p.SessionID()
	if id != "tokacct" {
		t.Fatalf("pull session id = %q", id)
	}
	dep, _ := p.DepositAmount()
	if dep != 5_000_000 {
		t.Fatalf("pull deposit = %d", dep)
	}
}

func TestOpenPayloadPushRoundtripJSON(t *testing.T) {
	p := NewOpenPush("chan1", "1000000", "signer1", "txsig")
	raw, _ := json.Marshal(p)
	s := string(raw)
	if !strings.Contains(s, `"mode":"push"`) || !strings.Contains(s, `"channelId":"chan1"`) {
		t.Fatalf("push json missing fields: %s", s)
	}
	if strings.Contains(s, "tokenAccount") {
		t.Fatalf("push json should omit tokenAccount: %s", s)
	}
	var back OpenPayload
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if back.Mode != SessionModePush || back.ChannelID != "chan1" {
		t.Fatalf("push roundtrip mismatch: %+v", back)
	}
}

func TestSaltSerializesAsStringAndAcceptsNumber(t *testing.T) {
	const salt uint64 = 18446744073709551608 // u64::MAX - 7
	p := NewOpenPaymentChannel("chan1", "1000000", "payer1", "payee1", "mint1", salt, 900, "signer1", "txsig")
	raw, _ := json.Marshal(p)
	if !strings.Contains(string(raw), `"salt":"18446744073709551608"`) {
		t.Fatalf("salt not serialized as string: %s", raw)
	}
	var back OpenPayload
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if back.Salt == nil || *back.Salt != salt {
		t.Fatalf("salt string roundtrip mismatch: %v", back.Salt)
	}

	legacy := `{"mode":"push","channelId":"chan1","deposit":"1000000","payer":"payer1","payee":"payee1","mint":"mint1","salt":42,"gracePeriod":900,"authorizedSigner":"signer1","signature":"txsig"}`
	var legacyBack OpenPayload
	if err := json.Unmarshal([]byte(legacy), &legacyBack); err != nil {
		t.Fatal(err)
	}
	if legacyBack.Salt == nil || *legacyBack.Salt != 42 {
		t.Fatalf("legacy numeric salt not accepted: %v", legacyBack.Salt)
	}
}

func TestVoucherDataCumulativeAliasOnRead(t *testing.T) {
	// Serialize emits cumulativeAmount only.
	v := VoucherData{ChannelID: "c", Cumulative: "500000", ExpiresAt: 42}
	raw, _ := json.Marshal(v)
	s := string(raw)
	if !strings.Contains(s, `"cumulativeAmount":"500000"`) {
		t.Fatalf("expected cumulativeAmount: %s", s)
	}
	if strings.Contains(s, `"cumulative":`) {
		t.Fatalf("should not emit legacy cumulative: %s", s)
	}
	// Deserialize accepts the legacy "cumulative" alias.
	var back VoucherData
	if err := json.Unmarshal([]byte(`{"channelId":"c","cumulative":"700","expiresAt":1}`), &back); err != nil {
		t.Fatal(err)
	}
	if back.Cumulative != "700" {
		t.Fatalf("cumulative alias not read: %q", back.Cumulative)
	}
}

func TestSessionActionTopUpTag(t *testing.T) {
	action := SessionAction{Action: ActionTopUp, TopUp: &TopUpPayload{ChannelID: "chan1", NewDeposit: "9000000", Signature: "txsig"}}
	raw, _ := json.Marshal(action)
	if !strings.Contains(string(raw), `"action":"topUp"`) {
		t.Fatalf("topUp tag mismatch: %s", raw)
	}
	var back SessionAction
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if back.Action != ActionTopUp || back.TopUp == nil || back.TopUp.NewDeposit != "9000000" {
		t.Fatalf("topUp roundtrip mismatch: %+v", back)
	}
}

func TestSessionActionOpenAndVoucherRoundtrip(t *testing.T) {
	open := SessionAction{Action: ActionOpen, Open: ptr(NewOpenPush("chan123", "5000000", "signer123", "sig456"))}
	raw, _ := json.Marshal(open)
	if !strings.Contains(string(raw), `"action":"open"`) || !strings.Contains(string(raw), `"mode":"push"`) {
		t.Fatalf("open action json mismatch: %s", raw)
	}
	var back SessionAction
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if back.Action != ActionOpen || back.Open.ChannelID != "chan123" {
		t.Fatalf("open roundtrip mismatch")
	}

	voucher := SessionAction{Action: ActionVoucher, Voucher: &VoucherPayload{Voucher: SignedVoucher{
		Data: VoucherData{ChannelID: "chan1", Cumulative: "500000", ExpiresAt: 1, Nonce: ptrU64(3)}, Signature: "sig",
	}}}
	raw, _ = json.Marshal(voucher)
	if !strings.Contains(string(raw), `"action":"voucher"`) {
		t.Fatalf("voucher action tag missing: %s", raw)
	}
	var back2 SessionAction
	if err := json.Unmarshal(raw, &back2); err != nil {
		t.Fatal(err)
	}
	if back2.Voucher.Voucher.Data.Cumulative != "500000" || *back2.Voucher.Voucher.Data.Nonce != 3 {
		t.Fatalf("voucher roundtrip mismatch")
	}
}

func TestSessionActionCloseOmitsVoucher(t *testing.T) {
	action := SessionAction{Action: ActionClose, Close: &ClosePayload{ChannelID: "chan1"}}
	raw, _ := json.Marshal(action)
	if strings.Contains(string(raw), "voucher") {
		t.Fatalf("close without voucher should omit voucher: %s", raw)
	}
}

func TestMeteringDirectiveAmountParse(t *testing.T) {
	d := MeteringDirective{DeliveryID: "d1", SessionID: "chan1", Amount: "125", Currency: "USDC", Sequence: 7, ExpiresAt: DefaultSessionExpiresAt}
	v, err := d.AmountBaseUnits()
	if err != nil || v != 125 {
		t.Fatalf("amount = %d err=%v", v, err)
	}
	bad := MeteringDirective{Amount: "nope"}
	if _, err := bad.AmountBaseUnits(); err == nil {
		t.Fatalf("expected error for bad amount")
	}
}

func TestOpenPayloadDepositErrors(t *testing.T) {
	push := NewOpenPush("chan1", "bad", "s", "sig")
	if _, err := push.DepositAmount(); err == nil {
		t.Fatalf("expected invalid deposit error")
	}
	push.Deposit = ""
	if _, err := push.DepositAmount(); err == nil {
		t.Fatalf("expected missing deposit error")
	}
	push.ChannelID = ""
	if _, err := push.SessionID(); err == nil {
		t.Fatalf("expected missing channelId error")
	}
}

func TestNewOpenPaymentChannelDefaultsPushMode(t *testing.T) {
	p := NewOpenPaymentChannel("chan1", "1000000", "payer1", "payee1", "mint1", 42, 60, "signer1", "sig")
	if p.Mode != SessionModePush || p.Salt == nil || *p.Salt != 42 || p.GracePeriod == nil || *p.GracePeriod != 60 {
		t.Fatalf("payment channel push defaults mismatch: %+v", p)
	}
}

func TestMeteringUsageAmountParse(t *testing.T) {
	u := MeteringUsage{DeliveryID: "d1", Amount: "42"}
	v, err := u.AmountBaseUnits()
	if err != nil || v != 42 {
		t.Fatalf("usage amount = %d err=%v", v, err)
	}
	bad := MeteringUsage{Amount: "bad"}
	if _, err := bad.AmountBaseUnits(); err == nil {
		t.Fatalf("expected error for bad usage amount")
	}
}

func TestVoucherDataMessageBytesLen(t *testing.T) {
	v := VoucherData{ChannelID: "11111111111111111111111111111111", Cumulative: "1000", ExpiresAt: 42}
	bytes, err := v.MessageBytes()
	if err != nil || len(bytes) != 48 {
		t.Fatalf("message bytes len = %d err=%v", len(bytes), err)
	}
	bad := VoucherData{ChannelID: "not-base58!!", Cumulative: "1", ExpiresAt: 1}
	if _, err := bad.MessageBytes(); err == nil {
		t.Fatalf("expected invalid channel id error")
	}
}

func ptr(p OpenPayload) *OpenPayload { return &p }
func ptrU64(v uint64) *uint64        { return &v }
