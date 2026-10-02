# Rust txv1 wire fixture

`v1-rust-full-config.hex` is the 701-byte Rust-generated
`v1GoldenTxFullConfig` fixture from
[solana-go v2.1.0](https://github.com/solana-foundation/solana-go/blob/4bfe959f4b96f36fc471ee3c47734d05bf3b71a7/transaction_v1_test.go#L26-L42).
Its signer seeds are public test data: 32 bytes of `1` and 32 bytes of `2`.

It covers two signers, all four inline config fields, three instructions,
empty instruction data and a 300-byte instruction. It is a codec/signing
conformance fixture, not an executable payment or a shared all-language vector.
