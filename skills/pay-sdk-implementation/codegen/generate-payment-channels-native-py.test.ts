import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { generatePaymentChannelsPython } from './generate-payment-channels-native-py.js';

function scratch(run: (directory: string) => void): void {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'paymentchannels-generator-test-'));
    try { run(directory); } finally { fs.rmSync(directory, { recursive: true, force: true }); }
}

test('output is deterministic, checked without writes, and stale generated files are removed', () => scratch((root) => {
    const output = path.join(root, 'client');
    assert.throws(() => generatePaymentChannelsPython(output, true), /differs/);
    assert.equal(fs.existsSync(output), false);
    generatePaymentChannelsPython(output);
    generatePaymentChannelsPython(output, true);
    const first = fs.readFileSync(path.join(output, '__init__.py'), 'utf8');
    fs.writeFileSync(path.join(output, 'stale.py'), '# Generated from idl/payment-channels.json.\n');
    assert.throws(() => generatePaymentChannelsPython(output, true), /differs/);
    assert.equal(fs.existsSync(path.join(output, 'stale.py')), true);
    generatePaymentChannelsPython(output);
    assert.equal(fs.existsSync(path.join(output, 'stale.py')), false);
    assert.equal(fs.readFileSync(path.join(output, '__init__.py'), 'utf8'), first);
    generatePaymentChannelsPython(output, true);
}));

test('check detects modified output and does not repair it', () => scratch((root) => {
    generatePaymentChannelsPython(root);
    const file = path.join(root, '__init__.py');
    fs.appendFileSync(file, '\n# drift\n');
    assert.throws(() => generatePaymentChannelsPython(root, true), /differs/);
    assert.match(fs.readFileSync(file, 'utf8'), /# drift/);
    generatePaymentChannelsPython(root);
    assert.doesNotMatch(fs.readFileSync(file, 'utf8'), /# drift/);
}));

test('an unrelated output directory is preserved', () => scratch((root) => {
    const file = path.join(root, 'important.py');
    fs.writeFileSync(file, 'important = True\n');
    assert.throws(() => generatePaymentChannelsPython(root), /non-generated/);
    assert.equal(fs.readFileSync(file, 'utf8'), 'important = True\n');
}));

test('generation refuses a symlink inside output', () => scratch((root) => {
    const output = path.join(root, 'client');
    fs.mkdirSync(output);
    const target = path.join(root, 'external.py');
    fs.writeFileSync(target, 'important = True\n');
    fs.symlinkSync(target, path.join(output, 'external.py'));
    assert.throws(() => generatePaymentChannelsPython(output), /symlinks/);
    assert.equal(fs.readFileSync(target, 'utf8'), 'important = True\n');
}));

test('generation refuses the repository and its ancestors', () => {
    const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
    assert.throws(() => generatePaymentChannelsPython(repo), /repository/);
    assert.throws(() => generatePaymentChannelsPython(path.dirname(repo)), /ancestor/);
});
