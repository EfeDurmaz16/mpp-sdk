import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { createFromJson, type RootNode } from 'codama';

import { renderPaymentChannelsPython } from './render-payment-channels-python.js';

const idl = fs.readFileSync(new URL('../../../idl/payment-channels.json', import.meta.url), 'utf8');
const root = (): RootNode => createFromJson(idl).getRoot();

function changed(path: string, value: unknown): RootNode {
  const input = root();
  const parts = path.split('.');
  let current: unknown = input;
  for (const part of parts.slice(0, -1)) {
    assert.ok(current !== null && typeof current === 'object');
    current = (current as Record<string, unknown>)[part];
  }
  assert.ok(current !== null && typeof current === 'object');
  (current as Record<string, unknown>)[parts.at(-1)!] = value;
  return input;
}

const files = renderPaymentChannelsPython(root());

test('renders the complete client deterministically without mutating its RootNode', () => {
  const input = root();
  const before = JSON.stringify(input);
  assert.deepEqual(renderPaymentChannelsPython(input), files);
  assert.deepEqual(renderPaymentChannelsPython(root()), files);
  assert.equal(JSON.stringify(input), before);
  assert.equal(files.size, 36);
  for (const [directory, expected] of [['types', 13], ['accounts', 1], ['instructions', 10], ['events', 2]] as const) {
    assert.equal([...files.keys()].filter((name) => name.startsWith(`${directory}/`) && !name.endsWith('__init__.py')).length, expected);
  }
  assert.deepEqual([...files.keys()], [...files.keys()].sort((a, b) => a.localeCompare(b)));
  for (const [name, content] of files) {
    assert.match(name, /^[a-zA-Z_][a-zA-Z0-9_/.]*\.py$/);
    assert.ok(content.endsWith('\n'));
    assert.doesNotMatch(content, /anchorpy|borsh_construct|\.layout|dataclass/);
  }
});

test('preserves explicit enum tags, full account discriminator and event prefixes', () => {
  assert.match(files.get('types/accountDiscriminator.py')!, /Channel = 1\n    ClosedChannel = 2/);
  assert.match(files.get('accounts/channel.py')!, /discriminator: Annotated\[int, U8, Field\(ge=1, le=1\)\] = 1/);
  assert.match(files.get('accounts/channel.py')!, /return cls.from_borsh\(data\)/);
  assert.match(files.get('events/opened.py')!, /a6ac61094d4cbd6d/);
  assert.match(files.get('events/payoutRedirected.py')!, /d116b9d754a75450/);
  assert.match(files.get('events/opened.py')!, /if value != DISCRIMINATOR/);
  assert.match(files.get('types/voucherArgs.py')!, /Array\(U8, 2\), Field\(min_length=2, max_length=2\)/);
});

test('separates SDK runtime imports from third-party and relative modules', () => {
  const open = files.get('instructions/open.py')!;
  assert.match(open, /from solders.pubkey import Pubkey\n\nfrom solana_pay_kit\._paycore\.program_client import WireModel\n\nfrom \.\./);
  assert.match(files.get('types/voucherArgs.py')!, /from pydantic import Field\n\nfrom solana_pay_kit\._paycore\.program_client import/);
});

test('instruction arguments use native models and IDL account defaults', () => {
  const open = files.get('instructions/open.py')!;
  assert.match(open, /from \.\.types.openArgs import OpenArgs as OpenArgsValue/);
  assert.match(open, /class OpenArgs\(TypedDict\):[\s\S]*openArgs: OpenArgsValue/);
  assert.match(open, /class _InstructionData\(WireModel\):\n    discriminator: Annotated\[int, U8, Field\(ge=1, le=1\)\] = 1/);
  assert.match(open, /eventAuthority: NotRequired\[Pubkey\]/);
  assert.match(open, /accounts.get\("eventAuthority", find_event_authority_pda\(program_id\)\[0\]\)/);
  assert.match(open, /accounts.get\("systemProgram", Pubkey.from_string\("11111111111111111111111111111111"\)\)/);
  assert.match(open, /keys.extend\(remaining_accounts\)/);
  assert.match(files.get('instructions/emitEvent.py')!, /Field\(ge=228, le=228\)\] = 228/);
});

test('retains all IDL error messages and fresh error construction', () => {
  const errors = files.get('errors/paymentChannels.py')!;
  assert.equal((errors.match(/^class \w+\(CustomError\):/gm) ?? []).length, 65);
  assert.match(errors, /msg = "A signature was required but not found"/);
  assert.match(errors, /return None if error_type is None else error_type\(logs\)/);
  assert.match(files.get('errors/__init__.py')!, /program_error_code\(error, program_id\)/);
});

for (const name of ['customError', 'programError', 'callable']) {
  test(`rejects the valid IDL error name ${name} that shadows a generated symbol`, () => {
    const input = createFromJson(JSON.stringify(changed('program.errors.0.name', name))).getRoot();
    assert.throws(() => renderPaymentChannelsPython(input), /error class .* collides with a generated module symbol/);
  });
}

for (const index of [0, 1]) {
  test(`rejects a payload field that shadows event ${index}'s generated prefix`, () => {
    const input = createFromJson(JSON.stringify(changed(`program.events.${index}.data.type.fields.0.name`, 'discriminator'))).getRoot();
    assert.throws(() => renderPaymentChannelsPython(input), /field discriminator collides with the generated event prefix/);
  });
}

for (const publicKey of ['1'.repeat(33), 'z'.repeat(44)]) {
  test(`rejects a base58 account default whose decoded width exceeds 32 bytes: ${publicKey}`, () => {
    const input = createFromJson(JSON.stringify(changed('program.instructions.0.accounts.9.defaultValue.publicKey', publicKey))).getRoot();
    assert.throws(() => renderPaymentChannelsPython(input), /invalid public key default: expected 32 decoded bytes/);
  });
}

const rejected: readonly [string, string, unknown][] = [
  ['unknown metadata', 'program.instructions.0.optionalAccountStrategy', 'programId'],
  ['unknown root metadata', 'extensions', []],
  ['unknown program metadata', 'program.constants', []],
  ['unknown leaf metadata', 'program.accounts.0.data.fields.0.type.display', {}],
  ['unknown node', 'program.definedTypes.0.type.fields.0.type.kind', 'mapTypeNode'],
  ['big-endian number', 'program.definedTypes.4.type.fields.0.type.endian', 'be'],
  ['unsupported number', 'program.definedTypes.4.type.fields.0.type.format', 'u128'],
  ['unsupported vector prefix', 'program.definedTypes.0.type.fields.0.type.count.prefix.format', 'u16'],
  ['invalid fixed count', 'program.definedTypes.7.type.fields.0.type.count.value', -1],
  ['non-u8 fixed array', 'program.definedTypes.7.type.fields.0.type.item.format', 'u64'],
  ['unresolved link', 'program.definedTypes.0.type.fields.0.type.item.name', 'missing'],
  ['recursive link', 'program.definedTypes.0.type.fields.0.type.item.name', 'distributeArgs'],
  ['cross-program link', 'program.definedTypes.0.type.fields.0.type.item.program', { kind: 'programLinkNode', name: 'other' }],
  ['duplicate enum tags', 'program.definedTypes.10.type.variants.1.discriminator', 1],
  ['out-of-range enum tag', 'program.definedTypes.10.type.variants.1.discriminator', 256],
  ['signed enum tag', 'program.definedTypes.10.type.size.format', 'i64'],
  ['unsafe identifier', 'program.definedTypes.4.type.fields.0.name', 'x);evil('],
  ['duplicate field', 'program.definedTypes.4.type.fields.1.name', 'salt'],
  ['changed account size', 'program.accounts.0.data.fields.10.type.count.value', 31],
  ['missing account discriminator', 'program.accounts.0.data.fields.0.name', 'tag'],
  ['instruction discriminator default', 'program.instructions.0.arguments.0.defaultValueStrategy', 'optional'],
  ['instruction discriminator offset', 'program.instructions.0.discriminators.0.offset', 1],
  ['instruction discriminator range', 'program.instructions.0.arguments.0.defaultValue.number', 256],
  ['instruction duplicate discriminator', 'program.instructions.1.arguments.0.defaultValue.number', 1],
  ['argument default', 'program.instructions.0.arguments.1.defaultValue', { kind: 'numberValueNode', number: 1 }],
  ['optional account', 'program.instructions.0.accounts.0.isOptional', true],
  ['either signer', 'program.instructions.0.accounts.0.isSigner', 'either'],
  ['default PDA override', 'program.instructions.0.accounts.12.defaultValue.programId', { kind: 'publicKeyValueNode', publicKey: '11111111111111111111111111111111' }],
  ['unsupported remaining source', 'program.instructions.6.remainingAccounts.0.value.name', 'otherAccounts'],
  ['event prefix mismatch', 'program.events.0.discriminators.0.constant.value.data', '0000000000000000'],
  ['event wrong prefix size', 'program.events.0.data.prefix.0.type.size', 7],
  ['event unknown bytes encoding', 'program.events.0.data.prefix.0.value.encoding', 'base64'],
  ['unsupported PDA encoding', 'program.pdas.0.seeds.0.type.encoding', 'base16'],
  ['oversized PDA seed', 'program.pdas.0.seeds.0.value.string', 'a'.repeat(33)],
  ['duplicate error code', 'program.errors.1.code', 0],
  ['error overflow', 'program.errors.1.code', 2 ** 32],
  ['extra program', 'additionalPrograms', [root().program]],
  ['unsupported version', 'version', '2.0.0'],
];
for (const [name, path, value] of rejected) {
  test(`rejects ${name} before returning generated output`, () => {
    assert.throws(() => renderPaymentChannelsPython(changed(path, value)), /Unsupported PaymentChannels IDL/);
  });
}

test('error messages are safely quoted as Python literals', () => {
  const generated = renderPaymentChannelsPython(changed('program.errors.0.message', 'quote " slash \\ newline\n unicode é'));
  assert.match(generated.get('errors/paymentChannels.py')!, /msg = "quote \\" slash \\\\ newline\\n unicode \\u00e9"/);
});
