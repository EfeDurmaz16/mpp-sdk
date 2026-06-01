//! Rust cross-SDK conformance-vector runner.
//!
//! Honors the same stdin/stdout contract as the TypeScript reference runner
//! (`harness/src/conformance/ts-runner.ts`) and the Go runner
//! (`go/cmd/conformance/main.go`): read one conformance vector as JSON on
//! stdin, drive the real `solana-mpp` client build (`build_charge_transaction`),
//! server RPC-free pre-broadcast verify
//! (`verify_charge_transaction_pre_broadcast`), and the canonical-JSON /
//! base64url encoders for the requested mode, and emit one `RunnerResult` line
//! as JSON on stdout.
//!
//! The oracle for build/verify vectors is the DECODED SEMANTIC SHAPE of the
//! transaction (fee payer, transfer set, compute caps, memos) rather than raw
//! bytes, because signatures and account ordering can legitimately differ
//! across SDKs. The canonical-bytes mode pins exact bytes for the JCS /
//! base64url vectors where byte-for-byte agreement is the whole point.
//!
//! The run is deterministic and RPC-free: build/verify vectors pin a recent
//! blockhash and either an explicit token program or one resolvable by
//! currency, so no live validator is contacted. The bogus RPC URL means any
//! vector that under-specifies its inputs surfaces as a clear runner reject
//! rather than a silent network call.

use std::io::Read;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use solana_mpp::client::{build_charge_transaction_with_options, BuildChargeTransactionOptions};
use solana_mpp::protocol::solana::{programs, MethodDetails, Split};
use solana_mpp::server::verify_charge_transaction_pre_broadcast;
use solana_mpp::{base64url_encode, ChargeRequest};
use solana_rpc_client::rpc_client::RpcClient;
use solana_transaction::Transaction;

const DEFAULT_NETWORK: &str = "mainnet";
const DEFAULT_SPL_DECIMALS: u8 = 6;

// ── Vector schema (mirrors harness/src/conformance/schema.ts) ──

#[derive(Deserialize)]
struct Vector {
    id: String,
    mode: String,
    #[serde(default)]
    input: VectorInput,
}

#[derive(Default, Deserialize)]
struct VectorInput {
    #[serde(default)]
    request: Option<VectorChargeRequest>,
    #[serde(default)]
    transaction: Option<String>,
    #[serde(rename = "signerSecretKey", default)]
    signer_secret_key: Option<Vec<u8>>,
    #[serde(rename = "rpcFixtures", default)]
    rpc_fixtures: Option<RpcFixtures>,
    #[serde(default)]
    value: Option<Value>,
    #[serde(rename = "encodeBase64Url", default)]
    encode_base64_url: Option<EncodeBase64Url>,
}

#[derive(Deserialize)]
struct VectorChargeRequest {
    amount: String,
    currency: String,
    #[serde(rename = "externalId", default)]
    external_id: Option<String>,
    #[serde(default)]
    recipient: Option<String>,
    #[serde(rename = "payTo", default)]
    pay_to: Option<String>,
    #[serde(default)]
    asset: Option<String>,
    #[serde(rename = "methodDetails", default)]
    method_details: Option<VectorMethodDetails>,
    #[serde(rename = "computeUnitLimit", default)]
    compute_unit_limit: Option<u32>,
    #[serde(rename = "computeUnitPrice", default)]
    compute_unit_price: Option<String>,
}

#[derive(Default, Deserialize)]
struct VectorMethodDetails {
    #[serde(default)]
    network: Option<String>,
    #[serde(default)]
    decimals: Option<u8>,
    #[serde(rename = "tokenProgram", default)]
    token_program: Option<String>,
    #[serde(rename = "recentBlockhash", default)]
    recent_blockhash: Option<String>,
    #[serde(rename = "feePayer", default)]
    fee_payer: Option<bool>,
    #[serde(rename = "feePayerKey", default)]
    fee_payer_key: Option<String>,
    #[serde(default)]
    splits: Option<Vec<Split>>,
}

#[derive(Default, Deserialize)]
struct RpcFixtures {
    #[serde(rename = "mintOwners", default)]
    mint_owners: Option<std::collections::HashMap<String, String>>,
}

#[derive(Deserialize)]
struct EncodeBase64Url {
    #[serde(rename = "hexBytes", default)]
    hex_bytes: Option<String>,
    #[serde(default)]
    utf8: Option<String>,
}

// ── Result schema (mirrors harness/src/conformance/schema.ts RunnerResult) ──

#[derive(Serialize)]
struct Transfer {
    kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    destination: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mint: Option<String>,
    amount: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    decimals: Option<u8>,
    #[serde(rename = "tokenProgram", skip_serializing_if = "Option::is_none")]
    token_program: Option<String>,
}

#[derive(Serialize)]
struct TransactionShape {
    #[serde(rename = "feePayer", skip_serializing_if = "Option::is_none")]
    fee_payer: Option<String>,
    transfers: Vec<Transfer>,
    #[serde(rename = "forbiddenPrograms")]
    forbidden_programs: Vec<String>,
    #[serde(rename = "maxComputeUnitLimit", skip_serializing_if = "Option::is_none")]
    max_compute_unit_limit: Option<u32>,
    #[serde(rename = "maxComputeUnitPrice", skip_serializing_if = "Option::is_none")]
    max_compute_unit_price: Option<String>,
    memo: Vec<String>,
}

#[derive(Serialize)]
struct ExactBytes {
    #[serde(rename = "canonicalJson", skip_serializing_if = "Option::is_none")]
    canonical_json: Option<String>,
    #[serde(rename = "base64Url", skip_serializing_if = "Option::is_none")]
    base64_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    bytes: Option<Vec<u8>>,
}

#[derive(Serialize)]
struct RunnerResult {
    id: String,
    outcome: String,
    #[serde(rename = "transactionShape", skip_serializing_if = "Option::is_none")]
    transaction_shape: Option<TransactionShape>,
    #[serde(rename = "exactBytes", skip_serializing_if = "Option::is_none")]
    exact_bytes: Option<ExactBytes>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

fn rejected(id: &str, message: String) -> RunnerResult {
    RunnerResult {
        id: id.to_string(),
        outcome: "reject".to_string(),
        transaction_shape: None,
        exact_bytes: None,
        error: Some(message),
    }
}

#[tokio::main]
async fn main() {
    let mut raw = String::new();
    if std::io::stdin().read_to_string(&mut raw).is_err() {
        eprintln!("rust conformance runner failed to read stdin");
        std::process::exit(1);
    }
    let raw = raw.trim();
    if raw.is_empty() {
        eprintln!("rust conformance runner received empty stdin");
        std::process::exit(1);
    }
    let vector: Vector = match serde_json::from_str(raw) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("rust conformance runner failed to parse vector: {e}");
            std::process::exit(1);
        }
    };

    let result = run_vector(&vector).await;
    match serde_json::to_string(&result) {
        Ok(line) => println!("{line}"),
        Err(e) => {
            eprintln!("rust conformance runner failed to serialize result: {e}");
            std::process::exit(1);
        }
    }
}

async fn run_vector(vector: &Vector) -> RunnerResult {
    match vector.mode.as_str() {
        "canonical-bytes" => match run_canonical_bytes(vector) {
            Ok(eb) => RunnerResult {
                id: vector.id.clone(),
                outcome: "accept".to_string(),
                transaction_shape: None,
                exact_bytes: Some(eb),
                error: None,
            },
            Err(e) => rejected(&vector.id, e),
        },
        "build-transaction" => match build_transaction(vector).await {
            Ok(tx) => match shape_from_transaction(&tx) {
                Ok(shape) => RunnerResult {
                    id: vector.id.clone(),
                    outcome: "accept".to_string(),
                    transaction_shape: Some(shape),
                    exact_bytes: None,
                    error: None,
                },
                Err(e) => rejected(&vector.id, e),
            },
            Err(e) => rejected(&vector.id, e),
        },
        "verify-transaction" => {
            let tx = match vector.input.transaction.clone() {
                Some(tx) => tx,
                None => match build_transaction(vector).await {
                    Ok(tx) => tx,
                    Err(e) => return rejected(&vector.id, e),
                },
            };
            if let Err(e) = verify_transaction(vector, &tx) {
                return rejected(&vector.id, e);
            }
            match shape_from_transaction(&tx) {
                Ok(shape) => RunnerResult {
                    id: vector.id.clone(),
                    outcome: "accept".to_string(),
                    transaction_shape: Some(shape),
                    exact_bytes: None,
                    error: None,
                },
                Err(e) => rejected(&vector.id, e),
            }
        }
        other => rejected(&vector.id, format!("unsupported-mode: {other}")),
    }
}

/// Resolve the charge fields and `MethodDetails` the Rust SDK consumes,
/// applying the same precedence rules as the TS and Go reference runners:
/// top-level `asset` / `payTo` win over `currency` / `recipient`, and the
/// token program resolves explicit -> rpc-fixture mint owner ->
/// default-by-currency so the build path stays RPC-free.
fn flatten_request(
    req: &VectorChargeRequest,
    mint_owners: Option<&std::collections::HashMap<String, String>>,
) -> Result<(String, String, String, MethodDetails), String> {
    let currency = req.asset.clone().unwrap_or_else(|| req.currency.clone());
    let recipient = req
        .pay_to
        .clone()
        .or_else(|| req.recipient.clone())
        .ok_or_else(|| "vector request is missing recipient/payTo".to_string())?;

    let md = req.method_details.as_ref();
    let network = md
        .and_then(|m| m.network.clone())
        .unwrap_or_else(|| DEFAULT_NETWORK.to_string());

    let mut details = MethodDetails {
        network: Some(network.clone()),
        ..Default::default()
    };
    if let Some(md) = md {
        details.recent_blockhash = md.recent_blockhash.clone();
        details.fee_payer = md.fee_payer;
        details.fee_payer_key = md.fee_payer_key.clone();
        details.splits = md.splits.clone();
        details.decimals = md.decimals;
        details.token_program = md.token_program.clone();
    }

    let is_sol = currency.eq_ignore_ascii_case("sol");

    if details.token_program.is_none() && !is_sol {
        let resolved_mint =
            solana_mpp::resolve_stablecoin_mint(&currency, Some(network.as_str()))
                .unwrap_or(currency.as_str())
                .to_string();
        details.token_program = Some(match mint_owners.and_then(|m| m.get(&resolved_mint)) {
            Some(owner) => owner.clone(),
            None => solana_mpp::default_token_program_for_currency(
                &currency,
                Some(network.as_str()),
            )
            .to_string(),
        });
    }

    if details.decimals.is_none() && !is_sol {
        details.decimals = Some(DEFAULT_SPL_DECIMALS);
    }

    Ok((req.amount.clone(), currency, recipient, details))
}

/// Drive the real Rust client build path and return the base64 wire
/// transaction. The bogus RPC URL keeps the build RPC-free: any vector that
/// fails to pin a blockhash or token program surfaces as a clear reject.
async fn build_transaction(vector: &Vector) -> Result<String, String> {
    let input = &vector.input;
    let req = input
        .request
        .as_ref()
        .ok_or_else(|| "build/verify vector is missing input.request".to_string())?;
    let secret = input
        .signer_secret_key
        .as_ref()
        .ok_or_else(|| "build/verify vector is missing input.signerSecretKey".to_string())?;
    if secret.len() != 64 {
        return Err(format!(
            "signerSecretKey must be 64 bytes, got {}",
            secret.len()
        ));
    }
    let mut key_bytes = [0u8; 64];
    key_bytes.copy_from_slice(secret);
    let signer = solana_keychain::MemorySigner::from_bytes(&key_bytes)
        .map_err(|e| format!("invalid signer key: {e}"))?;

    let mint_owners = input
        .rpc_fixtures
        .as_ref()
        .and_then(|f| f.mint_owners.as_ref());
    let (amount, currency, recipient, details) = flatten_request(req, mint_owners)?;

    let mut options = BuildChargeTransactionOptions {
        external_id: req.external_id.clone(),
        ..Default::default()
    };
    options.compute_unit_limit = req.compute_unit_limit;
    if let Some(price) = req.compute_unit_price.as_ref() {
        options.compute_unit_price = Some(
            price
                .parse::<u64>()
                .map_err(|_| format!("invalid computeUnitPrice: {price}"))?,
        );
    }

    // Bogus RPC: a missing blockhash or token program throws against this URL,
    // surfacing as a clear reject instead of a silent live network call.
    let rpc = RpcClient::new("http://127.0.0.1:1".to_string());

    let payload = build_charge_transaction_with_options(
        &signer,
        &rpc,
        &amount,
        &currency,
        &recipient,
        &details,
        options,
    )
    .await
    .map_err(|e| e.to_string())?;

    match payload {
        solana_mpp::protocol::solana::CredentialPayload::Transaction { transaction } => {
            Ok(transaction)
        }
        _ => Err("build produced a non-transaction credential payload".to_string()),
    }
}

/// Drive the Rust server's RPC-free pre-broadcast verify.
fn verify_transaction(vector: &Vector, transaction_b64: &str) -> Result<(), String> {
    let input = &vector.input;
    let req = input
        .request
        .as_ref()
        .ok_or_else(|| "verify vector is missing input.request".to_string())?;
    let mint_owners = input
        .rpc_fixtures
        .as_ref()
        .and_then(|f| f.mint_owners.as_ref());
    let (amount, currency, recipient, details) = flatten_request(req, mint_owners)?;

    let network = details
        .network
        .clone()
        .unwrap_or_else(|| DEFAULT_NETWORK.to_string());

    let request = ChargeRequest {
        amount,
        currency,
        recipient: Some(recipient),
        external_id: req.external_id.clone(),
        ..Default::default()
    };

    verify_charge_transaction_pre_broadcast(transaction_b64, &request, &details, &network)
        .map_err(|e| e.to_string())
}

/// Drive the wire canonical-JSON (RFC 8785 JCS) and base64url encoders.
fn run_canonical_bytes(vector: &Vector) -> Result<ExactBytes, String> {
    let mut eb = ExactBytes {
        canonical_json: None,
        base64_url: None,
        bytes: None,
    };
    let input = &vector.input;

    if let Some(value) = input.value.as_ref() {
        let canonical = serde_json_canonicalizer::to_string(value)
            .map_err(|e| format!("canonical JSON encode failed: {e}"))?;
        eb.base64_url = Some(base64url_encode(canonical.as_bytes()));
        eb.canonical_json = Some(canonical);
    }

    if let Some(enc) = input.encode_base64_url.as_ref() {
        if let Some(hex) = enc.hex_bytes.as_ref() {
            let bytes = decode_hex(hex)?;
            eb.base64_url = Some(base64url_encode(&bytes));
            eb.bytes = Some(bytes);
        } else if let Some(utf8) = enc.utf8.as_ref() {
            eb.base64_url = Some(base64url_encode(utf8.as_bytes()));
        }
    }

    Ok(eb)
}

fn decode_hex(input: &str) -> Result<Vec<u8>, String> {
    if !input.len().is_multiple_of(2) {
        return Err("hex string has odd length".to_string());
    }
    let mut out = Vec::with_capacity(input.len() / 2);
    let bytes = input.as_bytes();
    for chunk in bytes.chunks(2) {
        let hi = hex_nibble(chunk[0])?;
        let lo = hex_nibble(chunk[1])?;
        out.push((hi << 4) | lo);
    }
    Ok(out)
}

fn hex_nibble(c: u8) -> Result<u8, String> {
    match c {
        b'0'..=b'9' => Ok(c - b'0'),
        b'a'..=b'f' => Ok(c - b'a' + 10),
        b'A'..=b'F' => Ok(c - b'A' + 10),
        _ => Err(format!("invalid hex character: {}", c as char)),
    }
}

/// Decode a base64 (standard-alphabet) legacy wire transaction into the
/// semantic shape the conformance driver asserts against. Mirrors the TS
/// reference decoder (`harness/src/conformance/decode.ts`) and the Go decoder:
/// fee payer is account[0], SPL transfers come from transferChecked
/// (discriminator 12), SOL transfers from the System Program transfer
/// (discriminator 2), memos from the Memo Program, compute caps from the
/// ComputeBudget program.
fn shape_from_transaction(transaction_b64: &str) -> Result<TransactionShape, String> {
    let bytes =
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, transaction_b64)
            .map_err(|e| format!("invalid base64 transaction: {e}"))?;
    let tx: Transaction =
        bincode::deserialize(&bytes).map_err(|e| format!("invalid transaction: {e}"))?;

    let keys = &tx.message.account_keys;
    if keys.is_empty() {
        return Err("transaction has no account keys".to_string());
    }

    let account_at = |accounts: &[u8], pos: usize| -> Option<String> {
        let idx = *accounts.get(pos)? as usize;
        keys.get(idx).map(|k| k.to_string())
    };

    let mut shape = TransactionShape {
        fee_payer: Some(keys[0].to_string()),
        transfers: Vec::new(),
        forbidden_programs: Vec::new(),
        max_compute_unit_limit: None,
        max_compute_unit_price: None,
        memo: Vec::new(),
    };

    for ix in &tx.message.instructions {
        let program = match keys.get(ix.program_id_index as usize) {
            Some(k) => k.to_string(),
            None => continue,
        };
        let data = &ix.data;

        if program == programs::COMPUTE_BUDGET_PROGRAM {
            if data.len() == 5 && data[0] == 2 {
                shape.max_compute_unit_limit =
                    Some(u32::from_le_bytes(data[1..5].try_into().unwrap()));
            } else if data.len() == 9 && data[0] == 3 {
                shape.max_compute_unit_price =
                    Some(u64::from_le_bytes(data[1..9].try_into().unwrap()).to_string());
            }
            continue;
        }

        if program == programs::MEMO_PROGRAM {
            shape.memo.push(String::from_utf8_lossy(data).to_string());
            continue;
        }

        if program == programs::SYSTEM_PROGRAM {
            // System transfer: u32 LE discriminator 2 + u64 LE lamports.
            if data.len() >= 12 && u32::from_le_bytes(data[0..4].try_into().unwrap()) == 2 {
                if let Some(dest) = account_at(&ix.accounts, 1) {
                    shape.transfers.push(Transfer {
                        kind: "sol".to_string(),
                        destination: Some(dest),
                        mint: None,
                        amount: u64::from_le_bytes(data[4..12].try_into().unwrap()).to_string(),
                        decimals: None,
                        token_program: None,
                    });
                }
            }
            continue;
        }

        if program == programs::TOKEN_PROGRAM || program == programs::TOKEN_2022_PROGRAM {
            // transferChecked: discriminator 12, u64 amount at [1], decimals [9].
            if data.len() >= 10 && data[0] == 12 && ix.accounts.len() >= 4 {
                let mint = account_at(&ix.accounts, 1);
                let dest = account_at(&ix.accounts, 2);
                if let (Some(mint), Some(dest)) = (mint, dest) {
                    shape.transfers.push(Transfer {
                        kind: "spl".to_string(),
                        destination: Some(dest),
                        mint: Some(mint),
                        amount: u64::from_le_bytes(data[1..9].try_into().unwrap()).to_string(),
                        decimals: Some(data[9]),
                        token_program: Some(program),
                    });
                }
            }
            continue;
        }
    }

    Ok(shape)
}
