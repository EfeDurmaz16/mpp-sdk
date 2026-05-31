# frozen_string_literal: true

require "mpp/program/payment_channels"

module Mpp
  module Protocol
    module Intents
      # Session intent wire types.
      #
      # The session intent opens a payment channel between a client and server,
      # allowing incremental payments via off-chain signed vouchers backed by
      # the on-chain payment-channels program.
      #
      # Mirrors `rust/crates/mpp/src/protocol/intents/session.rs`. Load-bearing
      # parity points:
      #   - voucher 48-byte signing layout (channel || cumulative_le || expires_le)
      #   - `cumulativeAmount` wire name with a `cumulative` read alias
      #   - `salt` serialized as a decimal string, deserialized from string or number
      #   - the `topUp` action tag (capital U)
      #   - `deliveryId` commit idempotency (committed/replayed)
      module Session
        # Default session voucher/directive expiry: 2100-01-01T00:00:00Z.
        # Kept below JavaScript's max safe integer so JSON intermediaries do not
        # round it before the credential is decoded.
        DEFAULT_SESSION_EXPIRES_AT = 4_102_444_800

        # On-chain funding mechanism advertised by the server.
        module Mode
          PUSH = "push"
          PULL = "pull"
          ALL = [PUSH, PULL].freeze
        end

        # Voucher authority used when pull mode is advertised.
        module PullVoucherStrategy
          CLIENT_VOUCHER = "clientVoucher"
          OPERATED_VOUCHER = "operatedVoucher"
          ALL = [CLIENT_VOUCHER, OPERATED_VOUCHER].freeze
        end

        # Commit receipt status.
        module CommitStatus
          COMMITTED = "committed"
          REPLAYED = "replayed"
        end

        # Parse a u64 that may arrive as a decimal string or a JSON number.
        # Always returns an Integer (or nil when blank).
        def self.parse_optional_u64(value)
          return nil if value.nil?
          return value if value.is_a?(Integer)

          str = value.to_s
          raise ArgumentError, "salt must be a decimal string or unsigned 64-bit integer" unless str.match?(/\A[0-9]+\z/)

          Integer(str, 10)
        end

        # Session intent request — the payload embedded in a 402 challenge.
        class SessionRequest
          attr_reader :cap, :currency, :decimals, :network, :operator, :recipient,
            :splits, :program_id, :description, :external_id, :min_voucher_delta,
            :modes, :pull_voucher_strategy, :recent_blockhash

          def initialize(cap:, currency:, operator:, recipient:,
            decimals: nil, network: nil, splits: [], program_id: nil,
            description: nil, external_id: nil, min_voucher_delta: nil,
            modes: [], pull_voucher_strategy: nil, recent_blockhash: nil)
            @cap = cap.to_s
            @currency = currency.to_s
            @decimals = decimals
            @network = network
            @operator = operator.to_s
            @recipient = recipient.to_s
            @splits = splits || []
            @program_id = program_id
            @description = description
            @external_id = external_id
            @min_voucher_delta = min_voucher_delta
            @modes = modes || []
            @pull_voucher_strategy = pull_voucher_strategy
            @recent_blockhash = recent_blockhash
          end

          # Decode from wire JSON.
          def self.from_h(value)
            raise ArgumentError, "session request must be an object" unless value.is_a?(Hash)

            splits = (value["splits"] || []).map { |s| SessionSplit.from_h(s) }
            new(
              cap: value.fetch("cap"),
              currency: value.fetch("currency"),
              operator: value.fetch("operator"),
              recipient: value.fetch("recipient"),
              decimals: value["decimals"],
              network: value["network"],
              splits: splits,
              program_id: value["programId"],
              description: value["description"],
              external_id: value["externalId"],
              min_voucher_delta: value["minVoucherDelta"],
              modes: value["modes"] || [],
              pull_voucher_strategy: value["pullVoucherStrategy"],
              recent_blockhash: value["recentBlockhash"]
            )
          end

          # Serialize to the camelCase wire object, omitting empty/None fields.
          def to_h
            {
              "cap" => cap,
              "currency" => currency,
              "decimals" => decimals,
              "network" => network,
              "operator" => operator,
              "recipient" => recipient,
              "splits" => splits.empty? ? nil : splits.map(&:to_h),
              "programId" => program_id,
              "description" => description,
              "externalId" => external_id,
              "minVoucherDelta" => min_voucher_delta,
              "modes" => modes.empty? ? nil : modes,
              "pullVoucherStrategy" => pull_voucher_strategy,
              "recentBlockhash" => recent_blockhash
            }.compact
          end
        end

        # A payment split committed at channel open.
        class SessionSplit
          attr_reader :recipient, :bps

          def initialize(recipient:, bps:)
            @recipient = recipient.to_s
            @bps = Integer(bps)
          end

          def self.from_h(value)
            new(recipient: value.fetch("recipient"), bps: value.fetch("bps"))
          end

          def to_h
            {"recipient" => recipient, "bps" => bps}
          end
        end

        # The canonical content of a voucher signed by the client's session key.
        class VoucherData
          attr_reader :channel_id, :cumulative, :expires_at, :nonce

          def initialize(channel_id:, cumulative:, expires_at:, nonce: nil)
            @channel_id = channel_id.to_s
            @cumulative = cumulative.to_s
            @expires_at = Integer(expires_at)
            @nonce = nonce.nil? ? nil : Integer(nonce)
          end

          # Read both the canonical `cumulativeAmount` wire name and the
          # `cumulative` alias, mirroring the Rust serde alias.
          def self.from_h(value)
            raise ArgumentError, "voucher data must be an object" unless value.is_a?(Hash)

            cumulative = value["cumulativeAmount"]
            cumulative = value["cumulative"] if cumulative.nil?
            raise ArgumentError, "voucher data missing cumulativeAmount" if cumulative.nil?

            new(
              channel_id: value.fetch("channelId"),
              cumulative: cumulative,
              expires_at: value.fetch("expiresAt"),
              nonce: value["nonce"]
            )
          end

          # Serialize only as `cumulativeAmount` (canonical wire name).
          def to_h
            {
              "channelId" => channel_id,
              "cumulativeAmount" => cumulative,
              "expiresAt" => expires_at,
              "nonce" => nonce
            }.compact
          end

          # Parsed cumulative as Integer.
          def cumulative_i
            Integer(cumulative, 10)
          rescue ArgumentError
            raise ArgumentError, "invalid voucher cumulative: #{cumulative}"
          end

          # Serialize to the 48-byte payment-channels VoucherArgs bytes that the
          # client signs with Ed25519.
          def message_bytes
            ::Mpp::Program::PaymentChannels.voucher_message_bytes(
              channel_id: channel_id,
              cumulative_amount: cumulative_i,
              expires_at: expires_at
            )
          end
        end

        # A signed voucher authorizing cumulative payment up to `cumulative`.
        class SignedVoucher
          attr_reader :data, :signature

          def initialize(data:, signature:)
            @data = data
            @signature = signature.to_s
          end

          def self.from_h(value)
            raise ArgumentError, "signed voucher must be an object" unless value.is_a?(Hash)

            new(
              data: VoucherData.from_h(value.fetch("data")),
              signature: value.fetch("signature")
            )
          end

          def to_h
            {"data" => data.to_h, "signature" => signature}
          end
        end

        # The action submitted by the client in an Authorization header.
        # Discriminated by the `action` tag: open | voucher | commit | topUp | close.
        class SessionAction
          OPEN = "open"
          VOUCHER = "voucher"
          COMMIT = "commit"
          TOP_UP = "topUp"
          CLOSE = "close"

          # Decode a tagged action object into the matching payload, returning
          # `[action, payload]`.
          def self.from_h(value)
            raise ArgumentError, "session action must be an object" unless value.is_a?(Hash)

            action = value["action"]
            case action
            when OPEN then [OPEN, OpenPayload.from_h(value)]
            when VOUCHER then [VOUCHER, VoucherPayload.from_h(value)]
            when COMMIT then [COMMIT, CommitPayload.from_h(value)]
            when TOP_UP then [TOP_UP, TopUpPayload.from_h(value)]
            when CLOSE then [CLOSE, ClosePayload.from_h(value)]
            else
              raise ArgumentError, "unknown session action: #{action.inspect}"
            end
          end
        end

        # Payload for the `open` action.
        class OpenPayload
          attr_reader :mode, :channel_id, :deposit, :payer, :payee, :mint, :salt,
            :grace_period, :transaction, :token_account, :approved_amount, :owner,
            :init_multi_delegate_tx, :update_delegation_tx, :authorized_signer, :signature

          def initialize(mode:, authorized_signer:, signature:,
            channel_id: nil, deposit: nil, payer: nil, payee: nil, mint: nil,
            salt: nil, grace_period: nil, transaction: nil, token_account: nil,
            approved_amount: nil, owner: nil, init_multi_delegate_tx: nil,
            update_delegation_tx: nil)
            @mode = mode
            @channel_id = channel_id
            @deposit = deposit
            @payer = payer
            @payee = payee
            @mint = mint
            @salt = salt.nil? ? nil : Session.parse_optional_u64(salt)
            @grace_period = grace_period.nil? ? nil : Integer(grace_period)
            @transaction = transaction
            @token_account = token_account
            @approved_amount = approved_amount
            @owner = owner
            @init_multi_delegate_tx = init_multi_delegate_tx
            @update_delegation_tx = update_delegation_tx
            @authorized_signer = authorized_signer.to_s
            @signature = signature.to_s
          end

          # Construct a push payment-channel open payload.
          def self.push(channel_id:, deposit:, authorized_signer:, signature:)
            new(
              mode: Mode::PUSH, channel_id: channel_id, deposit: deposit.to_s,
              authorized_signer: authorized_signer, signature: signature
            )
          end

          # Construct a fully specified payment-channel open payload.
          def self.payment_channel(channel_id:, deposit:, payer:, payee:, mint:,
            salt:, grace_period:, authorized_signer:, signature:, mode: Mode::PUSH)
            new(
              mode: mode, channel_id: channel_id, deposit: deposit.to_s,
              payer: payer, payee: payee, mint: mint, salt: salt,
              grace_period: grace_period, authorized_signer: authorized_signer,
              signature: signature
            )
          end

          # Construct an operated-voucher pull open payload.
          def self.pull(token_account:, approved_amount:, owner:, authorized_signer:, signature:)
            new(
              mode: Mode::PULL, token_account: token_account,
              approved_amount: approved_amount.to_s, owner: owner,
              authorized_signer: authorized_signer, signature: signature
            )
          end

          def self.from_h(value)
            new(
              mode: value.fetch("mode"),
              channel_id: value["channelId"],
              deposit: value["deposit"],
              payer: value["payer"],
              payee: value["payee"],
              mint: value["mint"],
              salt: value["salt"],
              grace_period: value["gracePeriod"],
              transaction: value["transaction"],
              token_account: value["tokenAccount"],
              approved_amount: value["approvedAmount"],
              owner: value["owner"],
              init_multi_delegate_tx: value["initMultiDelegateTx"],
              update_delegation_tx: value["updateDelegationTx"],
              authorized_signer: value.fetch("authorizedSigner"),
              signature: value.fetch("signature")
            )
          end

          # Serialize to the tagged camelCase wire object, omitting None fields.
          # `salt` always serializes as a decimal string.
          def to_h
            {
              "action" => SessionAction::OPEN,
              "mode" => mode,
              "channelId" => channel_id,
              "deposit" => deposit,
              "payer" => payer,
              "payee" => payee,
              "mint" => mint,
              "salt" => salt&.to_s,
              "gracePeriod" => grace_period,
              "transaction" => transaction,
              "tokenAccount" => token_account,
              "approvedAmount" => approved_amount,
              "owner" => owner,
              "initMultiDelegateTx" => init_multi_delegate_tx,
              "updateDelegationTx" => update_delegation_tx,
              "authorizedSigner" => authorized_signer,
              "signature" => signature
            }.compact
          end

          # Session identifier used as the store key: channelId for push,
          # tokenAccount for operated-voucher pull.
          def session_id
            return channel_id unless channel_id.nil?

            case mode
            when Mode::PUSH
              raise ArgumentError, "push open missing channelId"
            else
              raise ArgumentError, "pull open missing channelId or tokenAccount" if token_account.nil?

              token_account
            end
          end

          # Deposit / approved amount for this open (base units), as Integer.
          def deposit_amount
            raw = deposit
            if raw.nil?
              case mode
              when Mode::PUSH
                raise ArgumentError, "push open missing deposit"
              else
                raise ArgumentError, "pull open missing deposit or approvedAmount" if approved_amount.nil?

                raw = approved_amount
              end
            end
            unless raw.to_s.match?(/\A[0-9]+\z/)
              raise ArgumentError, "invalid deposit amount: #{raw}"
            end

            Integer(raw.to_s, 10)
          end
        end

        # Payload for the `voucher` action.
        class VoucherPayload
          attr_reader :voucher

          def initialize(voucher:)
            @voucher = voucher
          end

          def self.from_h(value)
            new(voucher: SignedVoucher.from_h(value.fetch("voucher")))
          end

          def to_h
            {"action" => SessionAction::VOUCHER, "voucher" => voucher.to_h}
          end
        end

        # Server-issued metering directive attached to a delivered response.
        class MeteringDirective
          attr_reader :delivery_id, :session_id, :amount, :currency, :sequence,
            :expires_at, :commit_url, :proof

          def initialize(delivery_id:, session_id:, amount:, currency:, sequence:,
            expires_at:, commit_url: nil, proof: nil)
            @delivery_id = delivery_id.to_s
            @session_id = session_id.to_s
            @amount = amount.to_s
            @currency = currency.to_s
            @sequence = Integer(sequence)
            @expires_at = Integer(expires_at)
            @commit_url = commit_url
            @proof = proof
          end

          def self.from_h(value)
            new(
              delivery_id: value.fetch("deliveryId"),
              session_id: value.fetch("sessionId"),
              amount: value.fetch("amount"),
              currency: value.fetch("currency"),
              sequence: value.fetch("sequence"),
              expires_at: value.fetch("expiresAt"),
              commit_url: value["commitUrl"],
              proof: value["proof"]
            )
          end

          def to_h
            {
              "deliveryId" => delivery_id,
              "sessionId" => session_id,
              "amount" => amount,
              "currency" => currency,
              "sequence" => sequence,
              "expiresAt" => expires_at,
              "commitUrl" => commit_url,
              "proof" => proof
            }.compact
          end

          def amount_base_units
            Integer(amount, 10)
          rescue ArgumentError
            raise ArgumentError, "invalid metering amount: #{amount}"
          end
        end

        # Payload for the `commit` action.
        class CommitPayload
          attr_reader :delivery_id, :voucher

          def initialize(delivery_id:, voucher:)
            @delivery_id = delivery_id.to_s
            @voucher = voucher
          end

          def self.from_h(value)
            new(
              delivery_id: value.fetch("deliveryId"),
              voucher: SignedVoucher.from_h(value.fetch("voucher"))
            )
          end

          def to_h
            {
              "action" => SessionAction::COMMIT,
              "deliveryId" => delivery_id,
              "voucher" => voucher.to_h
            }
          end
        end

        # Result returned after a delivery commit is accepted.
        class CommitReceipt
          attr_reader :delivery_id, :session_id, :amount, :cumulative, :status

          def initialize(delivery_id:, session_id:, amount:, cumulative:, status:)
            @delivery_id = delivery_id.to_s
            @session_id = session_id.to_s
            @amount = amount.to_s
            @cumulative = cumulative.to_s
            @status = status
          end

          def to_h
            {
              "deliveryId" => delivery_id,
              "sessionId" => session_id,
              "amount" => amount,
              "cumulative" => cumulative,
              "status" => status
            }
          end
        end

        # Payload for the `topUp` action.
        class TopUpPayload
          attr_reader :channel_id, :new_deposit, :signature

          def initialize(channel_id:, new_deposit:, signature:)
            @channel_id = channel_id.to_s
            @new_deposit = new_deposit.to_s
            @signature = signature.to_s
          end

          def self.from_h(value)
            new(
              channel_id: value.fetch("channelId"),
              new_deposit: value.fetch("newDeposit"),
              signature: value.fetch("signature")
            )
          end

          def to_h
            {
              "action" => SessionAction::TOP_UP,
              "channelId" => channel_id,
              "newDeposit" => new_deposit,
              "signature" => signature
            }
          end

          def new_deposit_amount
            Integer(new_deposit, 10)
          rescue ArgumentError
            raise ArgumentError, "invalid newDeposit: #{new_deposit}"
          end
        end

        # Payload for the `close` action.
        class ClosePayload
          attr_reader :channel_id, :voucher

          def initialize(channel_id:, voucher: nil)
            @channel_id = channel_id.to_s
            @voucher = voucher
          end

          def self.from_h(value)
            voucher = value["voucher"].nil? ? nil : SignedVoucher.from_h(value["voucher"])
            new(channel_id: value.fetch("channelId"), voucher: voucher)
          end

          def to_h
            {
              "action" => SessionAction::CLOSE,
              "channelId" => channel_id,
              "voucher" => voucher&.to_h
            }.compact
          end
        end
      end
    end
  end
end
