package intents

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestDayPeriodMapsToHours(t *testing.T) {
	cases := map[uint64]uint64{1: 24, 30: 720, 365: 8760}
	for count, want := range cases {
		got, err := PeriodUnitDay.ToPeriodHours(count)
		if err != nil {
			t.Fatalf("count=%d: %v", count, err)
		}
		if got != want {
			t.Errorf("day*%d = %d, want %d", count, got, want)
		}
	}
}

func TestWeekPeriodMapsToHours(t *testing.T) {
	cases := map[uint64]uint64{1: 168, 52: 8736}
	for count, want := range cases {
		got, err := PeriodUnitWeek.ToPeriodHours(count)
		if err != nil {
			t.Fatalf("count=%d: %v", count, err)
		}
		if got != want {
			t.Errorf("week*%d = %d, want %d", count, got, want)
		}
	}
}

func TestPeriodCountOutOfRangeErrors(t *testing.T) {
	if _, err := PeriodUnitDay.ToPeriodHours(366); err == nil {
		t.Error("day*366 must error")
	}
	if _, err := PeriodUnitWeek.ToPeriodHours(53); err == nil {
		t.Error("week*53 must error")
	}
	if _, err := PeriodUnitDay.ToPeriodHours(0); err == nil {
		t.Error("count 0 must error")
	}
}

func TestUnsupportedPeriodUnitErrors(t *testing.T) {
	month := SubscriptionPeriodUnit("month")
	if _, err := month.ToPeriodHours(1); err == nil {
		t.Fatal("month must be rejected")
	}
}

func TestRequestSerializesCamelCase(t *testing.T) {
	req := SubscriptionRequest{
		Amount:              "10000000",
		Currency:            "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
		PeriodUnit:          PeriodUnitDay,
		PeriodCount:         "30",
		Recipient:           "9xAXssX9j7vuK99c7cFwqbixzL3bFrzPy9PUhCtDPAYJ",
		SubscriptionExpires: "2026-07-14T12:00:00Z",
		ExternalID:          "order-42",
	}
	raw, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	out := string(raw)
	for _, want := range []string{
		`"periodUnit":"day"`,
		`"periodCount":"30"`,
		`"subscriptionExpires":"2026-07-14T12:00:00Z"`,
		`"externalId":"order-42"`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("serialized JSON missing %s: %s", want, out)
		}
	}
}

func TestPeriodHoursValidatesRange(t *testing.T) {
	req := SubscriptionRequest{PeriodUnit: PeriodUnitDay, PeriodCount: "30"}
	got, err := req.PeriodHours()
	if err != nil || got != 720 {
		t.Fatalf("period_hours = %d, err = %v; want 720", got, err)
	}

	tooBig := SubscriptionRequest{PeriodUnit: PeriodUnitDay, PeriodCount: "400"}
	if _, err := tooBig.PeriodHours(); err == nil {
		t.Fatal("period_count 400 must error")
	}

	atBound := SubscriptionRequest{PeriodUnit: PeriodUnitDay, PeriodCount: "365"}
	if got, err := atBound.PeriodHours(); err != nil || got != 8760 {
		t.Fatalf("at-bound period_hours = %d, err = %v; want 8760", got, err)
	}
}

func TestParseAmountAndPeriodCount(t *testing.T) {
	req := SubscriptionRequest{Amount: "10000000", PeriodCount: "30"}
	if amount, err := req.ParseAmount(); err != nil || amount != 10_000_000 {
		t.Fatalf("amount = %d, err = %v", amount, err)
	}
	if count, err := req.ParsePeriodCount(); err != nil || count != 30 {
		t.Fatalf("count = %d, err = %v", count, err)
	}

	if _, err := (SubscriptionRequest{Amount: "not-a-number"}).ParseAmount(); err == nil {
		t.Fatal("bad amount must error")
	}
	if _, err := (SubscriptionRequest{PeriodCount: "abc"}).ParsePeriodCount(); err == nil {
		t.Fatal("bad period count must error")
	}
	if _, err := (SubscriptionRequest{Amount: "-5"}).ParseAmount(); err == nil {
		t.Fatal("negative amount must error")
	}
}

func TestRequestRoundTripsThroughJSON(t *testing.T) {
	const wire = `{"amount":"1","currency":"X","periodUnit":"week","periodCount":"2","recipient":"R"}`
	var req SubscriptionRequest
	if err := json.Unmarshal([]byte(wire), &req); err != nil {
		t.Fatal(err)
	}
	if req.PeriodUnit != PeriodUnitWeek || req.PeriodCount != "2" {
		t.Fatalf("decoded %+v", req)
	}
	if got, err := req.PeriodHours(); err != nil || got != 336 {
		t.Fatalf("week*2 period_hours = %d, err = %v; want 336", got, err)
	}
}
