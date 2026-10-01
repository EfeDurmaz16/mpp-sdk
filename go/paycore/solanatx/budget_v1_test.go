package solanatx

import (
	"math"
	"strings"
	"testing"

	solana "github.com/solana-foundation/solana-go/v2"
)

func TestCheckV1BudgetCaps(t *testing.T) {
	for _, test := range []struct {
		name     string
		config   solana.TransactionConfig
		maxUnits uint32
		maxPrice uint64
		want     string
	}{
		{"sponsored boundary", solana.TransactionConfig{}.WithComputeUnitLimit(200_000).WithPriorityFee(2_000), 200_000, 10_000, ""},
		{"sponsored excess", solana.TransactionConfig{}.WithComputeUnitLimit(200_000).WithPriorityFee(2_001), 200_000, 10_000, "priority fee"},
		{"general boundary", solana.TransactionConfig{}.WithComputeUnitLimit(200_000).WithPriorityFee(1_000_000), 200_000, 5_000_000, ""},
		{"general excess", solana.TransactionConfig{}.WithComputeUnitLimit(200_000).WithPriorityFee(1_000_001), 200_000, 5_000_000, "priority fee"},
		{"units excess", solana.TransactionConfig{}.WithComputeUnitLimit(200_001), 200_000, 10_000, "compute unit limit"},
		{"missing units", solana.TransactionConfig{}.WithPriorityFee(1), 200_000, 10_000, "must set computeUnitLimit"},
		{"zero units", solana.TransactionConfig{}.WithComputeUnitLimit(0), 200_000, 10_000, "greater than zero"},
		{"zero units with fee", solana.TransactionConfig{}.WithComputeUnitLimit(0).WithPriorityFee(1), 200_000, 10_000, "greater than zero"},
		{"no priority fee", solana.TransactionConfig{}.WithComputeUnitLimit(1), 200_000, 10_000, ""},
		{"zero priority fee", solana.TransactionConfig{}.WithComputeUnitLimit(1).WithPriorityFee(0), 200_000, 10_000, ""},
		{"fractional price rounds up", solana.TransactionConfig{}.WithComputeUnitLimit(3).WithPriorityFee(1), 200_000, 333_333, "priority fee"},
		{"rounded price boundary", solana.TransactionConfig{}.WithComputeUnitLimit(3).WithPriorityFee(1), 200_000, 333_334, ""},
		{"overflowing fee product", solana.TransactionConfig{}.WithComputeUnitLimit(200_000).WithPriorityFee(1 << 63), 200_000, 10_000, "priority fee"},
		{"maximum fee", solana.TransactionConfig{}.WithComputeUnitLimit(200_000).WithPriorityFee(math.MaxUint64), 200_000, 5_000_000, "priority fee"},
		{"large cap product", solana.TransactionConfig{}.WithComputeUnitLimit(math.MaxUint32).WithPriorityFee(math.MaxUint64), math.MaxUint32, math.MaxUint64, ""},
		{"zero price cap", solana.TransactionConfig{}.WithComputeUnitLimit(200_000).WithPriorityFee(1), 200_000, 0, "priority fee"},
	} {
		t.Run(test.name, func(t *testing.T) {
			tx := signedV1Transaction(t)
			tx.Message.TransactionConfig = test.config
			err := CheckV1BudgetCaps(tx, test.maxUnits, test.maxPrice)
			if test.want == "" {
				if err != nil {
					t.Fatal(err)
				}
			} else if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("err = %v, want %q", err, test.want)
			}
		})
	}
}

func TestCheckV1BudgetCapsRejectsIgnoredComputeInstructions(t *testing.T) {
	tx := signedV1Transaction(t)
	tx.Message.AccountKeys = append(tx.Message.AccountKeys, solana.ComputeBudget)
	// In v1 even a seemingly harmless ComputeBudget instruction is ignored by
	// the runtime. It must not become an alternative source of fee policy.
	tx.Message.Instructions = append(tx.Message.Instructions, solana.CompiledInstruction{
		ProgramIDIndex: uint16(len(tx.Message.AccountKeys) - 1), Data: []byte{3, 0, 0, 0, 0, 0, 0, 0, 0},
	})
	if err := CheckV1BudgetCaps(tx, 200_000, 10_000); err == nil || !strings.Contains(err.Error(), "must not contain ComputeBudget") {
		t.Fatalf("err = %v, want ignored-instruction rejection", err)
	}
}

func TestCheckV1BudgetCapsLeavesExistingVersionsUnchanged(t *testing.T) {
	for _, version := range []solana.MessageVersion{solana.MessageVersionLegacy, solana.MessageVersionV0} {
		tx := signedV1Transaction(t)
		tx.Message.TransactionConfig = solana.TransactionConfig{}
		if _, err := tx.Message.SetVersion(version); err != nil {
			t.Fatal(err)
		}
		if err := CheckV1BudgetCaps(tx, 0, 0); err != nil {
			t.Fatal(err)
		}
	}
}
