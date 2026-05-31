package subscriptions

import (
	"encoding/binary"
	"testing"

	solana "github.com/gagliardetto/solana-go"
)

func uniqueKey() solana.PublicKey {
	return solana.NewWallet().PublicKey()
}

func instructionData(t *testing.T, ix solana.Instruction) []byte {
	t.Helper()
	data, err := ix.Data()
	if err != nil {
		t.Fatalf("instruction data: %v", err)
	}
	return data
}

func TestDefaultProgramIDParses(t *testing.T) {
	if got := DefaultProgramID().String(); got != SubscriptionsProgramID {
		t.Fatalf("DefaultProgramID = %s, want %s", got, SubscriptionsProgramID)
	}
}

func TestInstructionDiscriminatorsMatchSpec(t *testing.T) {
	cases := map[string]struct {
		got, want uint8
	}{
		"initSA":      {InstructionInitializeSubscriptionAuthority, 0},
		"createPlan":  {InstructionCreatePlan, 7},
		"transferSub": {InstructionTransferSubscription, 10},
		"subscribe":   {InstructionSubscribe, 11},
		"cancel":      {InstructionCancelSubscription, 12},
	}
	for name, c := range cases {
		if c.got != c.want {
			t.Errorf("%s discriminator = %d, want %d", name, c.got, c.want)
		}
	}
}

func TestPDADerivationsDeterministic(t *testing.T) {
	program := DefaultProgramID()
	subscriber := uniqueKey()
	mint := uniqueKey()

	a1, _, err := FindSubscriptionAuthorityPDA(subscriber, mint, program)
	if err != nil {
		t.Fatal(err)
	}
	a2, _, _ := FindSubscriptionAuthorityPDA(subscriber, mint, program)
	if !a1.Equals(a2) {
		t.Fatal("SubscriptionAuthority PDA not deterministic")
	}

	owner := uniqueKey()
	plan, _, err := FindPlanPDA(owner, PlanIDSeed(7), program)
	if err != nil {
		t.Fatal(err)
	}
	sub1, _, err := FindSubscriptionPDA(plan, subscriber, program)
	if err != nil {
		t.Fatal(err)
	}
	sub2, _, _ := FindSubscriptionPDA(plan, subscriber, program)
	if !sub1.Equals(sub2) {
		t.Fatal("SubscriptionDelegation PDA not deterministic")
	}

	ev1, _, _ := FindEventAuthorityPDA(program)
	ev2, _, _ := FindEventAuthorityPDA(program)
	if !ev1.Equals(ev2) {
		t.Fatal("event_authority PDA not deterministic")
	}
}

func TestPDADerivationsDifferForDistinctInputs(t *testing.T) {
	program := DefaultProgramID()
	mint := uniqueKey()
	a1, _, _ := FindSubscriptionAuthorityPDA(uniqueKey(), mint, program)
	a2, _, _ := FindSubscriptionAuthorityPDA(uniqueKey(), mint, program)
	if a1.Equals(a2) {
		t.Fatal("distinct subscribers must derive distinct PDAs")
	}
}

func TestPlanIDSeedRoundTripsU64(t *testing.T) {
	const id uint64 = 0xdeadbeef1234
	seed := PlanIDSeed(id)
	if len(seed) != 8 {
		t.Fatalf("seed length = %d, want 8", len(seed))
	}
	if got := binary.LittleEndian.Uint64(seed); got != id {
		t.Fatalf("round-trip = %d, want %d", got, id)
	}
}

func TestParsePubkeyErrorsOnInvalid(t *testing.T) {
	if _, err := ParsePubkey("not-a-pubkey", "test"); err == nil {
		t.Fatal("expected error for invalid pubkey")
	}
}

func TestCreatePlanDataToBytesLayout(t *testing.T) {
	mint := uniqueKey()
	data := CreatePlanData{
		PlanID: 0x0102030405060708,
		Mint:   mint,
		Terms:  PlanTerms{Amount: 1_000_000, PeriodHours: 720, CreatedAt: 0},
	}
	bytes := data.ToBytes()
	if len(bytes) != 1+CreatePlanDataLen {
		t.Fatalf("len = %d, want %d", len(bytes), 1+CreatePlanDataLen)
	}
	if bytes[0] != InstructionCreatePlan {
		t.Fatalf("discriminator = %d, want %d", bytes[0], InstructionCreatePlan)
	}
	var want [8]byte
	binary.LittleEndian.PutUint64(want[:], 0x0102030405060708)
	if string(bytes[1:9]) != string(want[:]) {
		t.Fatal("plan_id little-endian mismatch")
	}
	// mint sits at offset 9.
	if string(bytes[9:41]) != string(mint.Bytes()) {
		t.Fatal("mint bytes mismatch")
	}
}

func TestCreatePlanDataLenIs456(t *testing.T) {
	if CreatePlanDataLen != 456 {
		t.Fatalf("CreatePlanDataLen = %d, want 456", CreatePlanDataLen)
	}
}

func TestNewCreatePlanDataZeroPadsMetadataURI(t *testing.T) {
	mint := uniqueKey()
	data, err := NewCreatePlanData(7, mint, PlanTerms{Amount: 1, PeriodHours: 24}, 0,
		[MaxPlanDestinations]solana.PublicKey{}, [MaxPlanPullers]solana.PublicKey{},
		"https://example.com/plan.json")
	if err != nil {
		t.Fatal(err)
	}
	if string(data.MetadataURI[:29]) != "https://example.com/plan.json" {
		t.Fatal("URI prefix mismatch")
	}
	for _, b := range data.MetadataURI[29:] {
		if b != 0 {
			t.Fatal("metadata URI not zero-padded")
		}
	}
}

func TestNewCreatePlanDataRejectsOverLengthURI(t *testing.T) {
	long := make([]byte, PlanMetadataURILen+1)
	for i := range long {
		long[i] = 'x'
	}
	_, err := NewCreatePlanData(7, uniqueKey(), PlanTerms{Amount: 1, PeriodHours: 24}, 0,
		[MaxPlanDestinations]solana.PublicKey{}, [MaxPlanPullers]solana.PublicKey{}, string(long))
	if err == nil {
		t.Fatal("expected error for over-length URI")
	}
}

func TestSubscribeDataToBytesLayout(t *testing.T) {
	mint := uniqueKey()
	data := SubscribeData{
		PlanID:                            42,
		PlanBump:                          254,
		ExpectedMint:                      mint,
		ExpectedAmount:                    10_000_000,
		ExpectedPeriodHours:               720,
		ExpectedCreatedAt:                 1_700_000_000,
		ExpectedSubscriptionAuthorityInit: 0,
	}
	bytes := data.ToBytes()
	if len(bytes) != 1+SubscribeDataLen {
		t.Fatalf("len = %d, want %d", len(bytes), 1+SubscribeDataLen)
	}
	if SubscribeDataLen != 73 {
		t.Fatalf("SubscribeDataLen = %d, want 73", SubscribeDataLen)
	}
	if bytes[0] != InstructionSubscribe {
		t.Fatalf("discriminator = %d, want %d", bytes[0], InstructionSubscribe)
	}
	if binary.LittleEndian.Uint64(bytes[1:9]) != 42 {
		t.Fatal("plan_id mismatch")
	}
	if bytes[9] != 254 {
		t.Fatalf("plan_bump = %d, want 254", bytes[9])
	}
	if string(bytes[10:42]) != string(mint.Bytes()) {
		t.Fatal("expected_mint bytes mismatch")
	}
}

func TestTransferDataToBytesSupportsDiscriminators(t *testing.T) {
	data := TransferData{Amount: 1_000, Delegator: uniqueKey(), Mint: uniqueKey()}
	if TransferDataLen != 72 {
		t.Fatalf("TransferDataLen = %d, want 72", TransferDataLen)
	}
	sub := data.ToBytes(InstructionTransferSubscription)
	if sub[0] != InstructionTransferSubscription || len(sub) != 1+TransferDataLen {
		t.Fatal("transfer_subscription layout mismatch")
	}
	fixed := data.ToBytes(InstructionTransferFixed)
	if fixed[0] != InstructionTransferFixed {
		t.Fatal("transfer_fixed discriminator mismatch")
	}
}

func TestBuildCreatePlanIxAccountOrder(t *testing.T) {
	program := DefaultProgramID()
	merchant := uniqueKey()
	planPDA := uniqueKey()
	tokenMint := uniqueKey()
	tokenProgram := solana.TokenProgramID
	data, _ := NewCreatePlanData(7, tokenMint, PlanTerms{Amount: 1, PeriodHours: 24}, 0,
		[MaxPlanDestinations]solana.PublicKey{}, [MaxPlanPullers]solana.PublicKey{}, "")
	ix := BuildCreatePlanIx(program, CreatePlanAccounts{
		Merchant: merchant, PlanPDA: planPDA, TokenMint: tokenMint, TokenProgram: tokenProgram,
	}, data)

	metas := ix.Accounts()
	if len(metas) != 5 {
		t.Fatalf("account count = %d, want 5", len(metas))
	}
	if !metas[0].PublicKey.Equals(merchant) || !metas[0].IsSigner || !metas[0].IsWritable {
		t.Fatal("slot 0 must be merchant signer+writable")
	}
	if !metas[1].PublicKey.Equals(planPDA) || metas[1].IsSigner || !metas[1].IsWritable {
		t.Fatal("slot 1 must be plan PDA writable non-signer")
	}
	if metas[2].IsWritable {
		t.Fatal("slot 2 token_mint must be readonly")
	}
	if !metas[3].PublicKey.Equals(solana.MustPublicKeyFromBase58(SystemProgramID)) {
		t.Fatal("slot 3 must be system program")
	}
	if !metas[4].PublicKey.Equals(tokenProgram) {
		t.Fatal("slot 4 must be token program")
	}
	if instructionData(t, ix)[0] != InstructionCreatePlan {
		t.Fatal("data discriminator mismatch")
	}
}

func TestBuildSubscribeIxIncludesOptionalPayer(t *testing.T) {
	program := DefaultProgramID()
	subscriber := uniqueKey()
	payer := uniqueKey()
	eventAuthority, _, _ := FindEventAuthorityPDA(program)
	ix := BuildSubscribeIx(program, SubscribeAccounts{
		Subscriber:               subscriber,
		Merchant:                 uniqueKey(),
		PlanPDA:                  uniqueKey(),
		SubscriptionPDA:          uniqueKey(),
		SubscriptionAuthorityPDA: uniqueKey(),
		EventAuthority:           eventAuthority,
		Payer:                    &payer,
	}, SubscribeData{PlanID: 7, PlanBump: 255, ExpectedMint: uniqueKey(), ExpectedAmount: 1, ExpectedPeriodHours: 24})

	metas := ix.Accounts()
	if len(metas) != 9 {
		t.Fatalf("account count = %d, want 9", len(metas))
	}
	if !metas[8].IsSigner || !metas[8].IsWritable {
		t.Fatal("payer at slot 8 must be signer+writable")
	}
	if instructionData(t, ix)[0] != InstructionSubscribe {
		t.Fatal("data discriminator mismatch")
	}
}

func TestBuildSubscribeIxOmitsPayerWhenUnset(t *testing.T) {
	program := DefaultProgramID()
	eventAuthority, _, _ := FindEventAuthorityPDA(program)
	ix := BuildSubscribeIx(program, SubscribeAccounts{
		Subscriber:               uniqueKey(),
		Merchant:                 uniqueKey(),
		PlanPDA:                  uniqueKey(),
		SubscriptionPDA:          uniqueKey(),
		SubscriptionAuthorityPDA: uniqueKey(),
		EventAuthority:           eventAuthority,
		Payer:                    nil,
	}, SubscribeData{PlanID: 7, PlanBump: 255, ExpectedMint: uniqueKey(), ExpectedAmount: 1, ExpectedPeriodHours: 24})
	if len(ix.Accounts()) != 8 {
		t.Fatalf("account count = %d, want 8", len(ix.Accounts()))
	}
}

func TestBuildTransferSubscriptionIxMarksOnlyCallerSigner(t *testing.T) {
	program := DefaultProgramID()
	eventAuthority, _, _ := FindEventAuthorityPDA(program)
	ix := BuildTransferSubscriptionIx(program, TransferSubscriptionAccounts{
		SubscriptionPDA:       uniqueKey(),
		PlanPDA:               uniqueKey(),
		SubscriptionAuthority: uniqueKey(),
		DelegatorATA:          uniqueKey(),
		ReceiverATA:           uniqueKey(),
		Caller:                uniqueKey(),
		TokenMint:             uniqueKey(),
		TokenProgram:          solana.TokenProgramID,
		EventAuthority:        eventAuthority,
	}, TransferData{Amount: 1_000_000, Delegator: uniqueKey(), Mint: uniqueKey()})

	metas := ix.Accounts()
	if len(metas) != 10 {
		t.Fatalf("account count = %d, want 10", len(metas))
	}
	signers := []int{}
	for i, m := range metas {
		if m.IsSigner {
			signers = append(signers, i)
		}
	}
	if len(signers) != 1 || signers[0] != 5 {
		t.Fatalf("signers = %v, want exactly [5]", signers)
	}
	if instructionData(t, ix)[0] != InstructionTransferSubscription {
		t.Fatal("data discriminator mismatch")
	}
}

func TestBuildCancelSubscriptionIx(t *testing.T) {
	program := DefaultProgramID()
	eventAuthority, _, _ := FindEventAuthorityPDA(program)
	subscriber := uniqueKey()
	ix := BuildCancelSubscriptionIx(program, CancelSubscriptionAccounts{
		Subscriber:      subscriber,
		PlanPDA:         uniqueKey(),
		SubscriptionPDA: uniqueKey(),
		EventAuthority:  eventAuthority,
	})
	metas := ix.Accounts()
	if len(metas) != 5 {
		t.Fatalf("account count = %d, want 5", len(metas))
	}
	if !metas[0].IsSigner || !metas[0].IsWritable {
		t.Fatal("subscriber must be signer+writable")
	}
	if !metas[2].IsWritable {
		t.Fatal("subscription PDA at slot 2 must be writable")
	}
	if len(instructionData(t, ix)) != 1 || instructionData(t, ix)[0] != InstructionCancelSubscription {
		t.Fatal("cancel data must be a single discriminator byte")
	}
}

func TestBuildInitializeSubscriptionAuthorityIx(t *testing.T) {
	program := DefaultProgramID()
	owner := uniqueKey()
	ix := BuildInitializeSubscriptionAuthorityIx(program, InitializeSubscriptionAuthorityAccounts{
		Owner:                 owner,
		SubscriptionAuthority: uniqueKey(),
		TokenMint:             uniqueKey(),
		UserATA:               uniqueKey(),
		TokenProgram:          solana.TokenProgramID,
	})
	metas := ix.Accounts()
	if len(metas) != 6 {
		t.Fatalf("account count = %d, want 6", len(metas))
	}
	if !metas[0].IsSigner || !metas[0].IsWritable {
		t.Fatal("owner must be signer+writable")
	}
	if len(instructionData(t, ix)) != 1 || instructionData(t, ix)[0] != InstructionInitializeSubscriptionAuthority {
		t.Fatal("init data must be a single discriminator byte")
	}
}
