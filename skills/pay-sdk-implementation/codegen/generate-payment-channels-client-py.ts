/** Generate the SDK native Python client from the vendored Codama IDL. */
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { generatePaymentChannelsPython } from './generate-payment-channels-native-py.js';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const output = path.join(repoRoot, 'python/src/solana_pay_kit/protocols/programs/paymentchannels');
const args = process.argv.slice(2);
if (args.length > 1 || (args[0] && args[0] !== '--check')) {
    throw new Error('Usage: tsx generate-payment-channels-client-py.ts [--check]');
}
generatePaymentChannelsPython(output, args[0] === '--check');
