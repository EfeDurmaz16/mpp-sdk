//! Shared transaction-signing helpers.
//!
//! Every transaction the kit signs is a `VersionedTransaction` (version 0 or
//! 1, see `core::tx`) and goes through `TransactionSigner::sign_transaction`,
//! so a backend that cannot raw-sign arbitrary bytes -- a hardware wallet --
//! works here, and version-1 messages are signed by the backend that knows
//! their layout.

use solana_keychain::TransactionSigner;
use solana_pubkey::Pubkey;
use solana_transaction::versioned::VersionedTransaction;

use crate::core::{Error, Result};

/// Sign the calling signer's required slot in a legacy or v0 transaction.
pub async fn sign_versioned_transaction_slot(
    signer: &dyn TransactionSigner,
    tx: &mut VersionedTransaction,
) -> Result<()> {
    let signer_pubkey = signer.pubkey();
    let signer_index = tx
        .message
        .static_account_keys()
        .iter()
        .position(|key| key == &signer_pubkey)
        .ok_or_else(|| Error::Other("signer not found in transaction accounts".into()))?;
    let required_signatures = tx.message.header().num_required_signatures as usize;
    if signer_index >= required_signatures {
        return Err(Error::Other(
            "signer is not a required transaction signer".into(),
        ));
    }
    if tx.signatures.len() != required_signatures {
        return Err(Error::Other(format!(
            "transaction has {} signature slots but requires {required_signatures}",
            tx.signatures.len()
        )));
    }

    // `sign_transaction` places the signature at this signer's own index and
    // leaves every other slot untouched, which is what the checks above have
    // just established is safe. The `signer_index` computed above is therefore
    // still the slot that changes; it stays computed because the validation
    // depends on it.
    signer
        .sign_transaction(tx)
        .await
        .map_err(|error| Error::Other(format!("transaction signing failed: {error}")))?;
    Ok(())
}

/// Co-sign the transaction's fee-payer slot after pinning the expected sponsor.
///
/// `expected_fee_payer` must be the pre-configured sponsor key, not a value
/// derived from `signer`. The sponsor must be both the supplied signer and
/// account key zero: accepting it at a later index would let a crafted
/// transaction leave its actual fee payer unsigned.
pub async fn cosign_versioned_fee_payer(
    signer: &dyn TransactionSigner,
    expected_fee_payer: &Pubkey,
    tx: &mut VersionedTransaction,
) -> Result<()> {
    if signer.pubkey() != *expected_fee_payer {
        return Err(Error::Other(
            "fee payer signer does not match the expected fee payer".into(),
        ));
    }
    if tx.message.static_account_keys().first() != Some(expected_fee_payer) {
        return Err(Error::Other(
            "transaction fee payer does not match the expected fee payer".into(),
        ));
    }
    sign_versioned_transaction_slot(signer, tx).await
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use solana_hash::Hash;
    use solana_keychain::transaction_util::TransactionUtil;
    use solana_keychain::{MemorySigner, SignTransactionResult, SignerError, SolanaSigner};
    use solana_message::v1;
    use solana_signature::Signature;
    use solana_system_interface::instruction as system_instruction;

    use super::*;
    use crate::core::tx::{build_unsigned, decode_bytes, serialize, TxVersion};

    struct TransactionOnlySigner {
        pubkey: Pubkey,
        signed_message: std::sync::Mutex<Vec<u8>>,
    }

    impl TransactionOnlySigner {
        fn new(pubkey: Pubkey) -> Self {
            Self {
                pubkey,
                signed_message: std::sync::Mutex::new(Vec::new()),
            }
        }
    }

    #[async_trait]
    impl SolanaSigner for TransactionOnlySigner {
        fn pubkey(&self) -> Pubkey {
            self.pubkey
        }

        async fn sign_message(
            &self,
            _message: &[u8],
        ) -> std::result::Result<Signature, SignerError> {
            // Stands in for a hardware backend: raw-byte signing is exactly what
            // such a signer cannot do, so the helpers must never reach this.
            Err(SignerError::Other(
                "sign_message must not be used to sign a transaction".into(),
            ))
        }

        async fn is_available(&self) -> bool {
            true
        }
    }

    #[async_trait]
    impl TransactionSigner for TransactionOnlySigner {
        async fn sign_transaction(
            &self,
            tx: &mut VersionedTransaction,
        ) -> std::result::Result<SignTransactionResult, SignerError> {
            *self.signed_message.lock().unwrap() = tx.message.serialize();
            let signature = Signature::from([7u8; 64]);
            TransactionUtil::add_signature_to_transaction(tx, &self.pubkey, signature)?;
            let signed = (TransactionUtil::serialize_transaction(tx)?, signature);
            Ok(TransactionUtil::classify_signed_transaction(tx, signed))
        }
    }

    #[tokio::test]
    async fn signs_only_the_calling_signers_required_slot() {
        for version in [TxVersion::V0, TxVersion::V1] {
            let fee_payer = Pubkey::new_unique();
            let signer = TransactionOnlySigner::new(Pubkey::new_unique());
            let recipient = Pubkey::new_unique();
            let instruction = system_instruction::transfer(&signer.pubkey(), &recipient, 1);
            let mut tx = build_unsigned(
                version,
                &fee_payer,
                &[instruction],
                Hash::new_unique(),
                None,
            )
            .unwrap();

            sign_versioned_transaction_slot(&signer, &mut tx)
                .await
                .unwrap();

            let signer_index = tx
                .message
                .static_account_keys()
                .iter()
                .position(|key| key == &signer.pubkey())
                .unwrap();
            assert_ne!(signer_index, 0);
            assert_eq!(tx.signatures[0], Signature::default());
            assert_eq!(tx.signatures[signer_index], Signature::from([7u8; 64]));
            assert_eq!(
                *signer.signed_message.lock().unwrap(),
                tx.message.serialize()
            );
        }
    }

    #[tokio::test]
    async fn cosigns_fee_payer_without_replacing_the_payer_signature() {
        for version in [TxVersion::V0, TxVersion::V1] {
            let fee_payer = TransactionOnlySigner::new(Pubkey::new_unique());
            let payer = Pubkey::new_unique();
            let recipient = Pubkey::new_unique();
            let instruction = system_instruction::transfer(&payer, &recipient, 1);
            let mut tx = build_unsigned(
                version,
                &fee_payer.pubkey(),
                &[instruction],
                Hash::new_unique(),
                None,
            )
            .unwrap();
            let payer_index = tx
                .message
                .static_account_keys()
                .iter()
                .position(|key| key == &payer)
                .unwrap();
            tx.signatures[payer_index] = Signature::from([9u8; 64]);

            cosign_versioned_fee_payer(&fee_payer, &fee_payer.pubkey(), &mut tx)
                .await
                .unwrap();

            assert_eq!(tx.signatures[0], Signature::from([7u8; 64]));
            assert_eq!(tx.signatures[payer_index], Signature::from([9u8; 64]));
            assert_eq!(
                *fee_payer.signed_message.lock().unwrap(),
                tx.message.serialize()
            );
        }
    }

    #[tokio::test]
    async fn memory_signers_preserve_valid_v1_signatures_through_wire_round_trip() {
        let [fee_payer, payer] = [1u8, 2u8].map(|seed| {
            let key = ed25519_dalek::SigningKey::from_bytes(&[seed; 32]);
            MemorySigner::from_bytes(&key.to_keypair_bytes()).unwrap()
        });
        let instruction = system_instruction::transfer(&payer.pubkey(), &Pubkey::new_unique(), 1);
        let mut tx = build_unsigned(
            TxVersion::V1,
            &fee_payer.pubkey(),
            &[instruction],
            Hash::new_unique(),
            None,
        )
        .unwrap();
        assert_eq!(tx.signatures.len(), 2);
        assert_eq!(
            &tx.message.static_account_keys()[..2],
            &[fee_payer.pubkey(), payer.pubkey()]
        );
        let message_bytes = tx.message.serialize();
        assert_eq!(message_bytes[0], v1::V1_PREFIX);

        sign_versioned_transaction_slot(&payer, &mut tx)
            .await
            .unwrap();
        let payer_signature = tx.signatures[1];
        assert_eq!(tx.signatures[0], Signature::default());

        cosign_versioned_fee_payer(&fee_payer, &fee_payer.pubkey(), &mut tx)
            .await
            .unwrap();
        assert_eq!(tx.signatures[1], payer_signature);
        assert_eq!(tx.message.serialize(), message_bytes);

        let wire = serialize(&tx).unwrap();
        assert_eq!(wire[0], v1::V1_PREFIX);
        let decoded = decode_bytes(&wire).unwrap();
        assert_eq!(decoded.message.serialize(), message_bytes);
        assert_eq!(decoded.signatures, tx.signatures);
        assert!(decoded.signatures[0].verify(fee_payer.pubkey().as_ref(), &message_bytes));
        assert!(decoded.signatures[1].verify(payer.pubkey().as_ref(), &message_bytes));
    }
}
