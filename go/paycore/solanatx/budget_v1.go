package solanatx

import (
	"fmt"
	"math/bits"

	solana "github.com/solana-foundation/solana-go/v2"
)

// CheckV1BudgetCaps bounds v1's inline compute budget before a payment verifier
// signs or broadcasts. Legacy/v0 budgets remain the verifier's responsibility.
// V1 priority fees are total lamports, rather than micro-lamports per CU.
func CheckV1BudgetCaps(tx *solana.Transaction, maxUnitLimit uint32, maxUnitPriceMicroLamports uint64) error {
	if tx.Message.GetVersion() != solana.MessageVersionV1 {
		return nil
	}
	for _, ix := range tx.Message.Instructions {
		if int(ix.ProgramIDIndex) >= len(tx.Message.AccountKeys) {
			return fmt.Errorf("invalid program index %d", ix.ProgramIDIndex)
		}
		if tx.Message.AccountKeys[ix.ProgramIDIndex].Equals(solana.ComputeBudget) {
			return fmt.Errorf("version 1 transactions must not contain ComputeBudget instructions")
		}
	}
	config := tx.Message.TransactionConfig
	if config.ComputeUnitLimit == nil {
		return fmt.Errorf("version 1 transaction config must set computeUnitLimit")
	}
	units := *config.ComputeUnitLimit
	if units == 0 {
		return fmt.Errorf("version 1 compute unit limit must be greater than zero")
	}
	if units > maxUnitLimit {
		return fmt.Errorf("compute unit limit %d exceeds maximum %d", units, maxUnitLimit)
	}
	if config.PriorityFee == nil {
		return nil
	}
	// ceil(fee * 1_000_000 / units) <= priceCap is exactly equivalent to
	// fee * 1_000_000 <= units * priceCap. Compare 128-bit products to avoid
	// overflowing either side, including a malicious maximum-u64 total fee.
	feeHigh, feeLow := bits.Mul64(*config.PriorityFee, 1_000_000)
	capHigh, capLow := bits.Mul64(uint64(units), maxUnitPriceMicroLamports)
	if feeHigh > capHigh || feeHigh == capHigh && feeLow > capLow {
		return fmt.Errorf("priority fee %d exceeds compute unit price maximum %d for %d units", *config.PriorityFee, maxUnitPriceMicroLamports, units)
	}
	return nil
}
