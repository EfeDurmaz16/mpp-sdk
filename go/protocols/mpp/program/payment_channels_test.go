package program

import (
	"encoding/binary"
	"testing"

	solana "github.com/gagliardetto/solana-go"
	"lukechampine.com/blake3"
)

func pk(b byte) solana.PublicKey {
	var out solana.PublicKey
	for i := range out {
		out[i] = b
	}
	return out
}

// Golden vector: mirrors voucher_message_is_program_borsh_layout in the Rust
// spine. channel=pk(9), cumulative=42, expires=1234.
func TestVoucherMessageBytesGoldenLayout(t *testing.T) {
	channel := pk(9)
	bytes := VoucherMessageBytes(channel, 42, 1234)
	if len(bytes) != VoucherMessageLen {
		t.Fatalf("voucher message length = %d, want %d", len(bytes), VoucherMessageLen)
	}
	if got := bytes[:32]; string(got) != string(channel[:]) {
		t.Fatalf("voucher channel prefix mismatch")
	}
	if got := binary.LittleEndian.Uint64(bytes[32:40]); got != 42 {
		t.Fatalf("voucher cumulative LE = %d, want 42", got)
	}
	if got := int64(binary.LittleEndian.Uint64(bytes[40:48])); got != 1234 {
		t.Fatalf("voucher expires LE = %d, want 1234", got)
	}
}

// Golden vector: mirrors voucher_data_message_bytes_with_nonce (channel=pk(3),
// cumulative=1000, expires=42).
func TestVoucherMessageBytesGoldenWithKnownValues(t *testing.T) {
	bytes := VoucherMessageBytes(pk(3), 1000, 42)
	if binary.LittleEndian.Uint64(bytes[32:40]) != 1000 {
		t.Fatalf("cumulative mismatch")
	}
	if int64(binary.LittleEndian.Uint64(bytes[40:48])) != 42 {
		t.Fatalf("expires mismatch")
	}
}

// Golden vector: mirrors distribution_hash_matches_program_preimage_shape in
// the Rust spine. The preimage is count(u32 LE) || (recipient(32)||bps(u16 LE)).
func TestDistributionHashGolden(t *testing.T) {
	recipients := []Distribution{
		{Recipient: pk(1), Bps: 7500},
		{Recipient: pk(2), Bps: 2500},
	}
	hasher := blake3.New(32, nil)
	count := make([]byte, 4)
	binary.LittleEndian.PutUint32(count, 2)
	_, _ = hasher.Write(count)
	r1 := pk(1)
	_, _ = hasher.Write(r1[:])
	bps := make([]byte, 2)
	binary.LittleEndian.PutUint16(bps, 7500)
	_, _ = hasher.Write(bps)
	r2 := pk(2)
	_, _ = hasher.Write(r2[:])
	binary.LittleEndian.PutUint16(bps, 2500)
	_, _ = hasher.Write(bps)
	var want [32]byte
	copy(want[:], hasher.Sum(nil))

	got := DistributionHash(recipients)
	if got != want {
		t.Fatalf("distribution hash mismatch\n got=%x\nwant=%x", got, want)
	}
}

func TestDistributionHashEmpty(t *testing.T) {
	got := DistributionHash(nil)
	hasher := blake3.New(32, nil)
	_, _ = hasher.Write([]byte{0, 0, 0, 0})
	var want [32]byte
	copy(want[:], hasher.Sum(nil))
	if got != want {
		t.Fatalf("empty distribution hash mismatch")
	}
}

// Golden vector: mirrors channel_pda_is_stable in the Rust spine. The derived
// PDA must equal CreateProgramAddress with the discovered bump.
func TestChannelPDAStable(t *testing.T) {
	programID := DefaultProgramID()
	channel, bump, err := FindChannelPDA(pk(1), pk(2), pk(3), pk(4), 99, programID)
	if err != nil {
		t.Fatal(err)
	}
	saltLE := make([]byte, 8)
	binary.LittleEndian.PutUint64(saltLE, 99)
	expected, err := solana.CreateProgramAddress([][]byte{
		[]byte(ChannelSeed),
		pk(1).Bytes(), pk(2).Bytes(), pk(3).Bytes(), pk(4).Bytes(),
		saltLE, {bump},
	}, programID)
	if err != nil {
		t.Fatal(err)
	}
	if !channel.Equals(expected) {
		t.Fatalf("channel PDA mismatch: %s != %s", channel, expected)
	}
}

func TestBuildOpenInstructionShape(t *testing.T) {
	params := OpenChannelParams{
		Payer:            pk(1),
		Payee:            pk(2),
		Mint:             pk(3),
		AuthorizedSigner: pk(4),
		Salt:             7,
		Deposit:          1_000_000,
		GracePeriod:      900,
		TokenProgram:     solana.TokenProgramID,
		ProgramID:        DefaultProgramID(),
	}
	ix, err := BuildOpenInstruction(params)
	if err != nil {
		t.Fatal(err)
	}
	if !ix.ProgramID().Equals(DefaultProgramID()) {
		t.Fatalf("open instruction program id mismatch")
	}
	if len(ix.Accounts()) != 13 {
		t.Fatalf("open instruction accounts = %d, want 13", len(ix.Accounts()))
	}
	data, err := ix.Data()
	if err != nil {
		t.Fatal(err)
	}
	if data[0] != openDiscriminator {
		t.Fatalf("open discriminator = %d, want %d", data[0], openDiscriminator)
	}
	// discriminator(1) + salt(8) + deposit(8) + grace(4) + recipients len(4) = 25
	if len(data) != 25 {
		t.Fatalf("open data len = %d, want 25", len(data))
	}
	if binary.LittleEndian.Uint64(data[1:9]) != 7 {
		t.Fatalf("open salt mismatch")
	}
	if binary.LittleEndian.Uint64(data[9:17]) != 1_000_000 {
		t.Fatalf("open deposit mismatch")
	}
	if binary.LittleEndian.Uint32(data[17:21]) != 900 {
		t.Fatalf("open grace mismatch")
	}
}

func TestBuildTopUpInstructionShape(t *testing.T) {
	ix, err := BuildTopUpInstruction(pk(1), pk(5), pk(3), 42, solana.TokenProgramID, DefaultProgramID())
	if err != nil {
		t.Fatal(err)
	}
	if len(ix.Accounts()) != 6 {
		t.Fatalf("topup accounts = %d, want 6", len(ix.Accounts()))
	}
	data, err := ix.Data()
	if err != nil {
		t.Fatal(err)
	}
	if data[0] != topUpDiscriminator {
		t.Fatalf("topup discriminator = %d, want %d", data[0], topUpDiscriminator)
	}
	if binary.LittleEndian.Uint64(data[1:9]) != 42 {
		t.Fatalf("topup amount mismatch")
	}
}

func TestBuildEd25519VerifyInstructionLayout(t *testing.T) {
	var sig [64]byte
	for i := range sig {
		sig[i] = byte(i)
	}
	message := VoucherMessageBytes(pk(9), 42, 1234)
	ix, err := BuildEd25519VerifyInstruction(pk(7), sig, message)
	if err != nil {
		t.Fatal(err)
	}
	if !ix.ProgramID().Equals(solana.MustPublicKeyFromBase58(Ed25519ProgramID)) {
		t.Fatalf("ed25519 program id mismatch")
	}
	data, err := ix.Data()
	if err != nil {
		t.Fatal(err)
	}
	// header: count=1, pad=0, then 7 u16 fields = 2 + 14 = 16
	if data[0] != 1 || data[1] != 0 {
		t.Fatalf("ed25519 header count/pad mismatch")
	}
	signer := pk(7)
	if string(data[16:48]) != string(signer[:]) {
		t.Fatalf("ed25519 public key offset mismatch")
	}
	if string(data[48:112]) != string(sig[:]) {
		t.Fatalf("ed25519 signature offset mismatch")
	}
	if string(data[112:]) != string(message) {
		t.Fatalf("ed25519 message offset mismatch")
	}
}
