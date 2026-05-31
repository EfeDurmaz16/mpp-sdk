package core

import (
	"context"
	"testing"
)

func makeChannelState(channelID string, deposit uint64) ChannelState {
	return ChannelState{ChannelID: channelID, AuthorizedSigner: "signer1", Deposit: deposit}
}

func TestChannelStorePutAndGet(t *testing.T) {
	store := NewMemoryChannelStore()
	ctx := context.Background()
	if _, ok, _ := store.GetChannel(ctx, "c1"); ok {
		t.Fatalf("expected missing channel")
	}
	if err := store.PutChannel(ctx, "c1", makeChannelState("c1", 1_000_000)); err != nil {
		t.Fatal(err)
	}
	state, ok, err := store.GetChannel(ctx, "c1")
	if err != nil || !ok {
		t.Fatalf("get failed: ok=%v err=%v", ok, err)
	}
	if state.Deposit != 1_000_000 || state.Cumulative != 0 {
		t.Fatalf("state mismatch: %+v", state)
	}
}

func TestChannelStoreUpdateInsertsAndModifies(t *testing.T) {
	store := NewMemoryChannelStore()
	ctx := context.Background()
	state, err := store.UpdateChannel(ctx, "c1", func(_ ChannelState, present bool) (ChannelState, error) {
		if present {
			t.Fatalf("expected absent on insert")
		}
		return makeChannelState("c1", 1_000_000), nil
	})
	if err != nil || state.Deposit != 1_000_000 {
		t.Fatalf("insert failed: %+v err=%v", state, err)
	}
	state, err = store.UpdateChannel(ctx, "c1", func(st ChannelState, present bool) (ChannelState, error) {
		if !present {
			t.Fatalf("expected present on modify")
		}
		st.Cumulative = 500_000
		return st, nil
	})
	if err != nil || state.Cumulative != 500_000 {
		t.Fatalf("modify failed: %+v err=%v", state, err)
	}
}

func TestChannelStoreUpdateErrorAborts(t *testing.T) {
	store := NewMemoryChannelStore()
	ctx := context.Background()
	_ = store.PutChannel(ctx, "c1", makeChannelState("c1", 1_000_000))
	_, err := store.UpdateChannel(ctx, "c1", func(_ ChannelState, _ bool) (ChannelState, error) {
		return ChannelState{}, ErrChannelNotFound
	})
	if err == nil {
		t.Fatalf("expected error to abort")
	}
	state, _, _ := store.GetChannel(ctx, "c1")
	if state.Deposit != 1_000_000 || state.Cumulative != 0 {
		t.Fatalf("state should be unchanged after aborted update: %+v", state)
	}
}

func TestChannelStoreCloneIsolatesSlices(t *testing.T) {
	store := NewMemoryChannelStore()
	ctx := context.Background()
	state := makeChannelState("c1", 1_000_000)
	state.PendingDeliveries = []PendingDelivery{{DeliveryID: "d1", Amount: 5}}
	_ = store.PutChannel(ctx, "c1", state)

	got, _, _ := store.GetChannel(ctx, "c1")
	got.PendingDeliveries[0].Amount = 999
	again, _, _ := store.GetChannel(ctx, "c1")
	if again.PendingDeliveries[0].Amount != 5 {
		t.Fatalf("stored state mutated through returned copy")
	}
}
