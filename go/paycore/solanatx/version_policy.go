package solanatx

import (
	"fmt"

	bin "github.com/gagliardetto/binary"
)

// checkWireVersion preserves the legacy/v0 policy before SDK decoding. The SDK
// also understands v1, whose envelope starts with the message rather than a
// signature count; enabling that format belongs to the separate v1 milestone.
func checkWireVersion(wire []byte) error {
	decoder := bin.NewBinDecoder(wire)
	first, err := decoder.Peek(1)
	if err != nil {
		return err
	}
	if first[0] == 0x81 {
		return fmt.Errorf("unsupported transaction message version 1")
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
