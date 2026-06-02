# frozen_string_literal: true

module PayCore
  module Solana
    # CAIP-2 network identifiers for Solana clusters. Used on the x402 wire
    # protocol where networks are referenced by their chain-agnostic ID
    # (see https://chainagnostic.org/CAIPs/caip-2 and the Solana CAIP-2
    # entry). Centralised here so x402 client + server do not duplicate
    # the devnet string literal.
    module Caip2
      MAINNET = "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp"
      DEVNET = "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"
      TESTNET = "solana:4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z"

      ALL = {
        "mainnet" => MAINNET,
        "devnet" => DEVNET,
        "testnet" => TESTNET
      }.freeze

      # Legacy bare-Solana network label (no cluster suffix). Mirrors the
      # spine `SOLANA_NETWORK` literal (rust/crates/x402/src/constants.rs:4).
      SOLANA_NETWORK = "solana"
      # Legacy cluster-suffixed devnet label used on the x402 v1 wire.
      SOLANA_DEVNET_LABEL = "solana-devnet"

      module_function

      # Resolve a friendly network name ("devnet") to its CAIP-2 ID, or
      # return the input unchanged if it already looks like a CAIP-2 ID.
      def resolve(network)
        return network if network.to_s.start_with?("solana:")

        ALL[network.to_s] || network
      end

      # Normalize a cluster name OR a legacy network string to its
      # canonical CAIP-2 ID. Mirrors the spine
      # `caip2_network_for_cluster` (rust/crates/x402/src/protocol/
      # schemes/exact/types.rs:31-38). Used by the x402 v1 server parse
      # arm to compare the credential's legacy `network` string against
      # the server's configured CAIP-2 network on the normalized form, so
      # a v1 string like "solana-devnet" or "solana" round-trips to the
      # correct CAIP-2 network. Unknown values fall through to MAINNET,
      # matching the spine's catch-all arm.
      def network_for_cluster(cluster)
        case cluster.to_s
        when MAINNET, SOLANA_NETWORK, "mainnet", "mainnet-beta" then MAINNET
        when TESTNET, "testnet", "solana-testnet" then TESTNET
        when "devnet", "localnet" then DEVNET
        when DEVNET, SOLANA_DEVNET_LABEL then DEVNET
        else MAINNET
        end
      end
    end
  end
end
