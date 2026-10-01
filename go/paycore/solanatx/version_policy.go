package solanatx

import (
	"fmt"

	bin "github.com/gagliardetto/binary"
)

// checkWireVersion distinguishes v1's message-first envelope from legacy/v0's
// signatures-first envelope. A v1 message inside the old envelope is malformed.
func checkWireVersion(wire []byte) error {
	decoder := bin.NewBinDecoder(wire)
	first, err := decoder.Peek(1)
	if err != nil {
		return err
	}
	if first[0] == 0x81 {
		return nil
	}
	if first[0] > 0x81 {
		return fmt.Errorf("unsupported transaction message version %d", first[0]&0x7f)
	}

	signatureCount, err := decoder.ReadCompactU16()
	if err != nil {
		return err
	}
	if signatureCount > decoder.Remaining()/64 {
		return fmt.Errorf("numSignatures %d is too large for remaining bytes %d", signatureCount, decoder.Remaining())
	}
	if _, err := decoder.ReadBytes(signatureCount * 64); err != nil {
		return err
	}
	prefix, err := decoder.ReadByte()
	if err != nil {
		return err
	}
	if prefix&0x80 != 0 && prefix != 0x80 {
		return fmt.Errorf("unsupported transaction message version %d", prefix&0x7f)
	}
	return nil
}
