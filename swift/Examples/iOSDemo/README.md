# iOSDemo

SwiftUI app that drives the full `mpp/charge/pull` flow against a local
merchant endpoint: tap pay, the app parses the `402 Payment Required`
challenge, signs the Solana charge transaction with a seeded demo
keypair, and replays the request to get a `200`.

![iOSDemo screenshot](docs/ios-demo-screenshot.png)

The app uses the umbrella `SolanaPayKit` surface (`MppHTTPClient`). The
demo keypair is for local testing only; swap in Mobile Wallet Adapter or
the Seeker Seed Vault for production.

## Run it

1. Start Surfpool (local Solana validator) on `http://127.0.0.1:8899`.

2. Start the bundled merchant server. It runs the same
   `402 -> charge -> 200` flow as the Python payment-links server and
   pre-funds the demo keypair with SOL + USDC on Surfpool:

   ```bash
   cd MerchantServer
   python3 serve.py            # listens on http://0.0.0.0:3004
   ```

3. Open `iOSDemo.xcodeproj` in Xcode and run the `iOSDemo` scheme on a
   simulator. The default endpoints (`http://127.0.0.1:8899` RPC,
   `http://127.0.0.1:3004/fortune` merchant) match the local setup and
   are editable in the UI. Tap **Pay** to settle a charge end-to-end.

To point at the hosted Surfpool RPC instead, set the RPC field to
`https://402.surfnet.dev:8899` and the merchant field to a deployed
endpoint.
