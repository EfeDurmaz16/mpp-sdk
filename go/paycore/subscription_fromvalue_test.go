package paycore

import "testing"

func TestSubscriptionMethodDetailsFromValueNil(t *testing.T) {
	md, err := SubscriptionMethodDetailsFromValue(nil)
	if err != nil {
		t.Fatalf("nil value must return zero details, got err %v", err)
	}
	if md.PlanID != "" || md.Mint != "" {
		t.Errorf("nil value must yield zero details, got %+v", md)
	}
}

func TestSubscriptionMethodDetailsFromValueUndecodable(t *testing.T) {
	// A JSON number cannot unmarshal into the struct, driving the decode-error branch.
	if _, err := SubscriptionMethodDetailsFromValue(42); err == nil {
		t.Fatal("non-object methodDetails must error")
	}
}
