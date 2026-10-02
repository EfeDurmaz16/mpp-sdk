/** Bounded native Python renderer for the vendored PaymentChannels Codama IDL. */
import type {
  DefinedTypeNode,
  EnumTypeNode,
  InstructionNode,
  RootNode,
  StructTypeNode,
  TypeNode,
} from 'codama';

const HEADER = '# Generated from idl/payment-channels.json. Do not edit by hand.\n';
const RUNTIME = 'solana_pay_kit._paycore.program_client';
const PROGRAM_ADDRESS = 'PAYMENT_CHANNELS_PROGRAM_ADDRESS';
const TYPE_NAMES = [
  'distributeArgs', 'payoutBeneficiary', 'redirectReason', 'distributionEntry',
  'openArgs', 'settleAndSealArgs', 'topUpArgs', 'voucherArgs', 'channelStatus',
  'settlementWatermarks', 'accountDiscriminator', 'opened', 'payoutRedirected',
];
const INSTRUCTION_NAMES = [
  'open', 'settle', 'topUp', 'settleAndSeal', 'requestClose', 'seal', 'distribute',
  'withdrawPayer', 'reclaim', 'emitEvent',
];
const PYTHON_KEYWORDS = new Set([
  'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break',
  'class', 'continue', 'def', 'del', 'elif', 'else', 'except', 'finally',
  'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'nonlocal',
  'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield',
]);
// Every admitted metadata key has a consumer below. New Codama features fail closed.
const KEYS: Readonly<Record<string, readonly string[]>> = {
  rootNode: ['kind', 'standard', 'version', 'program', 'additionalPrograms'],
  programNode: ['kind', 'name', 'publicKey', 'version', 'accounts', 'definedTypes', 'errors', 'events', 'instructions', 'pdas'],
  accountNode: ['kind', 'name', 'data'],
  definedTypeNode: ['kind', 'name', 'type'],
  structTypeNode: ['kind', 'fields'],
  structFieldTypeNode: ['kind', 'name', 'type'],
  numberTypeNode: ['kind', 'format', 'endian'],
  publicKeyTypeNode: ['kind'],
  definedTypeLinkNode: ['kind', 'name'],
  arrayTypeNode: ['kind', 'count', 'item'],
  fixedCountNode: ['kind', 'value'],
  prefixedCountNode: ['kind', 'prefix'],
  enumTypeNode: ['kind', 'size', 'variants'],
  enumEmptyVariantTypeNode: ['kind', 'name', 'discriminator'],
  errorNode: ['kind', 'name', 'code', 'message'],
  instructionNode: ['kind', 'name', 'accounts', 'arguments', 'discriminators', 'remainingAccounts'],
  instructionAccountNode: ['kind', 'name', 'isSigner', 'isWritable', 'defaultValue'],
  instructionArgumentNode: ['kind', 'name', 'type', 'defaultValue', 'defaultValueStrategy'],
  instructionRemainingAccountsNode: ['kind', 'isSigner', 'isWritable', 'value'],
  argumentValueNode: ['kind', 'name'],
  numberValueNode: ['kind', 'number'],
  publicKeyValueNode: ['kind', 'publicKey'],
  pdaValueNode: ['kind', 'pda', 'seeds'],
  pdaLinkNode: ['kind', 'name'],
  pdaNode: ['kind', 'name', 'seeds'],
  constantPdaSeedNode: ['kind', 'type', 'value'],
  stringTypeNode: ['kind', 'encoding'],
  stringValueNode: ['kind', 'string'],
  fieldDiscriminatorNode: ['kind', 'name', 'offset'],
  eventNode: ['kind', 'name', 'data', 'discriminators'],
  hiddenPrefixTypeNode: ['kind', 'prefix', 'type'],
  constantValueNode: ['kind', 'type', 'value'],
  constantDiscriminatorNode: ['kind', 'constant', 'offset'],
  fixedSizeTypeNode: ['kind', 'size', 'type'],
  bytesTypeNode: ['kind'],
  bytesValueNode: ['kind', 'encoding', 'data'],
};

function requireCondition(value: unknown, message: string): asserts value {
  if (!value) throw new Error(`Unsupported PaymentChannels IDL: ${message}`);
}

function identifier(name: string): string {
  requireCondition(/^[a-zA-Z][a-zA-Z0-9]*$/.test(name) && !PYTHON_KEYWORDS.has(name), `unsafe identifier ${JSON.stringify(name)}`);
  requireCondition(!['modelFields', 'modelConfig', 'toBorsh', 'fromBorsh'].includes(name), `reserved identifier ${name}`);
  return name;
}
const pascal = (name: string): string => identifier(name[0].toUpperCase() + name.slice(1));
// JSON string syntax is also valid Python string syntax; non-ASCII is escaped for safe source emission.
const literal = (value: string): string => JSON.stringify(value).replace(/[\u007f-\uffff]/g, (char) => `\\u${char.charCodeAt(0).toString(16).padStart(4, '0')}`);

function isPublicKey(value: string): boolean {
  if (!/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(value)) return false;
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  let integer = 0n;
  for (const character of value) integer = integer * 58n + BigInt(alphabet.indexOf(character));
  // Leading base58 ones encode zero bytes; other bytes come from the integer.
  let length = value.match(/^1*/)?.[0].length ?? 0;
  for (; integer > 0n; integer >>= 8n) length += 1;
  return length === 32;
}

function checkMetadata(value: unknown, location = 'root'): void {
  if (Array.isArray(value)) {
    value.forEach((item: unknown, index) => checkMetadata(item, `${location}[${index}]`));
    return;
  }
  if (value === null || typeof value !== 'object') return;
  const record = value as Record<string, unknown>;
  requireCondition(typeof record.kind === 'string' && KEYS[record.kind], `${location}: unknown node kind ${String(record.kind)}`);
  const allowed = KEYS[record.kind];
  for (const [key, item] of Object.entries(record)) {
    requireCondition(allowed.includes(key), `${location}.${key}: unsupported metadata`);
    if (key === 'name') {
      requireCondition(typeof item === 'string', `${location}.name must be a string`);
      identifier(item);
    }
    checkMetadata(item, `${location}.${key}`);
  }
}

function uniqueNames(nodes: readonly { name: string }[], label: string, expected?: readonly string[]): void {
  const names = nodes.map((node) => identifier(node.name));
  requireCondition(new Set(names).size === names.length, `${label}: duplicate names`);
  requireCondition(new Set(names.map((name) => name.toLowerCase())).size === names.length, `${label}: case-insensitive name collision`);
  if (expected) requireCondition([...names].sort().join(',') === [...expected].sort().join(','), `${label}: unsupported inventory`);
}

function enumVariants(type: EnumTypeNode): readonly { name: string; value: number }[] {
  requireCondition(type.size.kind === 'numberTypeNode' && type.size.format === 'u8' && type.size.endian === 'le', 'enum tags must be little-endian u8');
  const variants = type.variants ?? [];
  requireCondition(variants.length > 0, 'empty enum');
  uniqueNames(variants, 'enum variants');
  const result = variants.map((variant, index) => {
    requireCondition(variant.kind === 'enumEmptyVariantTypeNode', 'only empty enum variants are supported');
    const value = variant.discriminator ?? index;
    requireCondition(Number.isInteger(value) && value >= 0 && value <= 255, 'enum discriminator must fit u8');
    return { name: pascal(variant.name), value };
  });
  requireCondition(new Set(result.map(({ value }) => value)).size === result.length, 'duplicate enum discriminator');
  return result;
}

function checkTypeLinks(definitions: ReadonlyMap<string, DefinedTypeNode>): void {
  const done = new Set<string>();
  function visit(type: TypeNode, active: ReadonlySet<string>): void {
    if (type.kind === 'definedTypeLinkNode') {
      requireCondition(!active.has(type.name), `recursive type link ${type.name}`);
      const target = definitions.get(type.name);
      requireCondition(target, `unresolved type ${type.name}`);
      if (!done.has(type.name)) {
        visit(target.type, new Set([...active, type.name]));
        done.add(type.name);
      }
    } else if (type.kind === 'structTypeNode') {
      for (const field of type.fields ?? []) visit(field.type, active);
    } else if (type.kind === 'arrayTypeNode') {
      visit(type.item, active);
    }
  }
  for (const [name, node] of definitions) visit(node.type, new Set([name]));
}

function fixedSize(type: TypeNode, definitions: ReadonlyMap<string, DefinedTypeNode>): number | undefined {
  if (type.kind === 'publicKeyTypeNode') return 32;
  if (type.kind === 'numberTypeNode') {
    return ({ u8: 1, u16: 2, u32: 4, u64: 8, i64: 8 } as Record<string, number>)[type.format];
  }
  if (type.kind === 'enumTypeNode') return 1;
  if (type.kind === 'definedTypeLinkNode') {
    const target = definitions.get(type.name);
    return target ? fixedSize(target.type, definitions) : undefined;
  }
  if (type.kind === 'arrayTypeNode' && type.count.kind === 'fixedCountNode') {
    const item = fixedSize(type.item, definitions);
    return item === undefined ? undefined : item * type.count.value;
  }
  if (type.kind === 'structTypeNode') {
    let size = 0;
    for (const field of type.fields ?? []) {
      const next = fixedSize(field.type, definitions);
      if (next === undefined) return undefined;
      size += next;
    }
    return size;
  }
  return undefined;
}

class PythonModule {
  private readonly imports = new Map<string, Set<string>>();
  readonly lines: string[] = [];

  use(module: string, name: string): string {
    const names = this.imports.get(module) ?? new Set<string>();
    names.add(name);
    this.imports.set(module, names);
    return name;
  }

  finish(): string {
    const groups = [[], [], []] as string[][];
    for (const [module, names] of [...this.imports].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)) {
      const group = module.startsWith('.') ? 2 : ['typing', 'enum', 'collections.abc'].includes(module) ? 0 : 1;
      const rank = (name: string): number => /^[A-Z][A-Z0-9_]*$/.test(name) ? 0 : /^[A-Z]/.test(name) ? 1 : 2;
      const sorted = [...names].sort((a, b) => rank(a) - rank(b) || a.localeCompare(b, 'en', { numeric: true }));
      const aliases = sorted.filter((name) => name.includes(' as '));
      const direct = sorted.filter((name) => !name.includes(' as '));
      if (direct.length) {
        const line = `from ${module} import ${direct.join(', ')}`;
        groups[group].push(line.length <= 120 ? line : `from ${module} import (\n${direct.map((name) => `    ${name},`).join('\n')}\n)`);
      }
      for (const alias of aliases) groups[group].push(`from ${module} import ${alias}`);
    }
    const imports = groups.filter((group) => group.length).map((group) => group.join('\n')).join('\n\n');
    const body = this.lines.join('\n').trimEnd();
    const separator = /^(class |def )/.test(body) ? '\n\n\n' : '\n\n';
    return `${HEADER}${imports}${body ? separator + body : ''}\n`;
  }
}

function renderType(type: TypeNode, module: PythonModule, definitions: ReadonlyMap<string, DefinedTypeNode>, relative = '.', suffix = ''): string {
  switch (type.kind) {
    case 'numberTypeNode': {
      const names: Readonly<Record<string, string>> = { u8: 'UInt8', u16: 'UInt16', u32: 'UInt32', u64: 'UInt64', i64: 'Int64' };
      requireCondition(type.endian === 'le' && names[type.format], `unsupported number ${type.format}/${type.endian}`);
      return module.use(RUNTIME, names[type.format]);
    }
    case 'publicKeyTypeNode':
      return module.use(RUNTIME, 'PubkeyBytes');
    case 'definedTypeLinkNode': {
      requireCondition(definitions.has(type.name), `unresolved type ${type.name}`);
      const name = pascal(type.name);
      module.use(`${relative}${type.name}`, suffix ? `${name} as ${name}${suffix}` : name);
      return `${name}${suffix}`;
    }
    case 'arrayTypeNode': {
      const item = renderType(type.item, module, definitions, relative, suffix);
      if (type.count.kind === 'prefixedCountNode') {
        requireCondition(type.count.prefix.kind === 'numberTypeNode' && type.count.prefix.format === 'u32' && type.count.prefix.endian === 'le', 'vectors require a little-endian u32 count');
        return `list[${item}]`;
      }
      requireCondition(type.count.kind === 'fixedCountNode' && Number.isInteger(type.count.value) && type.count.value > 0, 'fixed arrays require a positive count');
      requireCondition(type.item.kind === 'numberTypeNode' && type.item.format === 'u8', 'only u8 fixed arrays are supported');
      module.use('typing', 'Annotated');
      module.use('pyborsh', 'Array');
      module.use('pyborsh', 'U8');
      module.use('pydantic', 'Field');
      const count = type.count.value;
      return `Annotated[list[${item}], Array(U8, ${count}), Field(min_length=${count}, max_length=${count})]`;
    }
    default:
      throw new Error(`Unsupported PaymentChannels IDL: type ${type.kind}`);
  }
}

function fields(type: StructTypeNode, module: PythonModule, definitions: ReadonlyMap<string, DefinedTypeNode>, relative = '.'): string[] {
  const values = type.fields ?? [];
  requireCondition(values.length > 0, 'empty structs');
  uniqueNames(values, 'struct fields');
  return values.map((field) => `    ${identifier(field.name)}: ${renderType(field.type, module, definitions, relative)}`);
}

function instruction(node: InstructionNode, definitions: ReadonlyMap<string, DefinedTypeNode>): string {
  const module = new PythonModule();
  const name = pascal(node.name);
  const arguments_ = node.arguments ?? [];
  const accounts = node.accounts ?? [];
  uniqueNames(arguments_, `${node.name} arguments`);
  uniqueNames(accounts, `${node.name} accounts`);
  const discriminator = arguments_[0];
  requireCondition(discriminator?.name === 'discriminator' && discriminator.type.kind === 'numberTypeNode' && discriminator.type.format === 'u8' && discriminator.type.endian === 'le', `${node.name}: missing leading u8 discriminator`);
  requireCondition(discriminator.defaultValueStrategy === 'omitted' && discriminator.defaultValue?.kind === 'numberValueNode', `${node.name}: discriminator must be an omitted constant`);
  const tag = discriminator.defaultValue.number;
  requireCondition(typeof tag === 'number' && Number.isInteger(tag) && tag >= 0 && tag <= 255, `${node.name}: discriminator must fit u8`);
  const marker = node.discriminators?.[0];
  requireCondition(node.discriminators?.length === 1 && marker?.kind === 'fieldDiscriminatorNode' && marker.name === 'discriminator' && marker.offset === 0, `${node.name}: unsupported discriminator metadata`);
  const args = arguments_.slice(1);
  for (const arg of args) requireCondition(arg.defaultValue === undefined && arg.defaultValueStrategy === undefined, `${node.name}.${arg.name}: argument defaults unsupported`);
  module.use('typing', 'TypedDict');
  module.use('solders.instruction', 'AccountMeta');
  module.use('solders.instruction', 'Instruction');
  module.use('solders.pubkey', 'Pubkey');
  module.use('pydantic', 'Field');
  module.use('typing', 'Annotated');
  module.use('pyborsh', 'U8');
  module.use(RUNTIME, 'WireModel');
  module.use('..program_id', PROGRAM_ADDRESS);
  const argFields = args.map((arg) => `    ${arg.name}: ${renderType(arg.type, module, definitions, '..types.', 'Value')}`);
  if (args.length) module.lines.push(`class ${name}Args(TypedDict):`, `    """Arguments for ${name}."""`, '', ...argFields, '', '');
  module.lines.push(`class ${name}Accounts(TypedDict):`, `    """Ordered account inputs for ${name}."""`, '');
  const keys: string[] = [];
  for (const account of accounts) {
    requireCondition(typeof account.isSigner === 'boolean' && typeof account.isWritable === 'boolean', `${node.name}.${account.name}: account flags must be boolean`);
    const value = account.defaultValue;
    let expression = `accounts[${literal(account.name)}]`;
    if (value) {
      module.use('typing', 'NotRequired');
      let fallback: string;
      if (value.kind === 'publicKeyValueNode') {
        requireCondition(isPublicKey(value.publicKey), 'invalid public key default: expected 32 decoded bytes');
        fallback = `Pubkey.from_string(${literal(value.publicKey)})`;
      } else {
        requireCondition(value.kind === 'pdaValueNode' && typeof value.pda !== 'string' && value.pda.kind === 'pdaLinkNode' && value.pda.name === 'eventAuthority' && (value.seeds ?? []).length === 0, `${node.name}.${account.name}: unsupported account default`);
        module.use('..pdas.index', 'find_event_authority_pda');
        fallback = 'find_event_authority_pda(program_id)[0]';
      }
      expression = `accounts.get(${literal(account.name)}, ${fallback})`;
    }
    module.lines.push(`    ${account.name}: ${value ? 'NotRequired[Pubkey]' : 'Pubkey'}`);
    keys.push('        AccountMeta(', `            pubkey=${expression},`, `            is_signer=${account.isSigner ? 'True' : 'False'},`, `            is_writable=${account.isWritable ? 'True' : 'False'},`, '        ),');
  }
  requireCondition(accounts.length > 0, `${node.name}: empty account list`);
  const remaining = node.remainingAccounts ?? [];
  requireCondition(remaining.length <= 1, `${node.name}: multiple remaining-account groups unsupported`);
  if (remaining.length) {
    const entry = remaining[0];
    requireCondition(node.name === 'distribute' && entry.isSigner === false && entry.isWritable === true && entry.value.kind === 'argumentValueNode' && entry.value.name === 'recipientTokenAccounts', `${node.name}: unsupported remaining accounts`);
  }
  module.lines.push('', '', 'class _InstructionData(WireModel):', `    discriminator: Annotated[int, U8, Field(ge=${tag}, le=${tag})] = ${tag}`, ...argFields, '', '', `def ${name}(`);
  if (args.length) module.lines.push(`    args: ${name}Args,`);
  module.lines.push(`    accounts: ${name}Accounts,`, `    program_id: Pubkey = ${PROGRAM_ADDRESS},`, '    remaining_accounts: list[AccountMeta] | None = None,', ') -> Instruction:', `    """Build the ${name} instruction from validated Borsh arguments."""`, '    keys = [', ...keys, '    ]', '    if remaining_accounts is not None:', '        keys.extend(remaining_accounts)', ...(args.length ? ['    data = _InstructionData(', ...args.map((arg) => `        ${arg.name}=args[${literal(arg.name)}],`), '    ).to_borsh()'] : ['    data = _InstructionData().to_borsh()']), '    return Instruction(program_id, data, keys)');
  return module.finish();
}

/** Render the complete supported IDL in memory; callers publish only after success. */
export function renderPaymentChannelsPython(root: RootNode): Map<string, string> {
  checkMetadata(root);
  requireCondition(root.standard === 'codama' && String(root.version) === '1.6.0' && (root.additionalPrograms ?? []).length === 0, 'unsupported Codama version or additional programs');
  const program = root.program;
  requireCondition(program.name === 'paymentChannels' && program.version === '0.1.0' && isPublicKey(program.publicKey) && program.publicKey === 'CHNLxYvVA28MJP9PrFuDXccuoGXAx7jBacfLEkahyGsX', 'unsupported program identity');
  const definedTypes = program.definedTypes ?? [];
  const instructions = program.instructions ?? [];
  const accounts = program.accounts ?? [];
  const events = program.events ?? [];
  const pdas = program.pdas ?? [];
  const errors = program.errors ?? [];
  uniqueNames(definedTypes, 'defined types', TYPE_NAMES);
  uniqueNames(instructions, 'instructions', INSTRUCTION_NAMES);
  uniqueNames(accounts, 'accounts', ['channel']);
  uniqueNames(events, 'events', ['opened', 'payoutRedirected']);
  uniqueNames(pdas, 'PDAs', ['eventAuthority']);
  uniqueNames(errors, 'errors');
  requireCondition(errors.length === 65, 'unsupported error inventory');
  const definitions = new Map(definedTypes.map((node) => [node.name as string, node]));
  checkTypeLinks(definitions);
  const output = new Map<string, string>();
  output.set('__init__.py', `${HEADER}"""Native PaymentChannels program client."""\n`);
  output.set('program_id.py', `${HEADER}from solders.pubkey import Pubkey\n\n${PROGRAM_ADDRESS} = Pubkey.from_string(${literal(program.publicKey)})\n`);
  for (const node of definedTypes) {
    const module = new PythonModule();
    const name = pascal(node.name);
    if (node.type.kind === 'enumTypeNode') {
      module.use('enum', 'IntEnum');
      module.lines.push(`class ${name}(IntEnum):`, `    """${name} wire tags from the IDL."""`, '', ...enumVariants(node.type).map((variant) => `    ${variant.name} = ${variant.value}`));
    } else {
      requireCondition(node.type.kind === 'structTypeNode', `${node.name}: unsupported defined type`);
      module.use(RUNTIME, 'WireModel');
      module.lines.push(`class ${name}(WireModel):`, `    """${name} Borsh payload."""`, '', ...fields(node.type, module, definitions));
    }
    output.set(`types/${node.name}.py`, module.finish());
  }
  const typeInit = new PythonModule();
  for (const node of definedTypes) typeInit.use(`.${node.name}`, `${pascal(node.name)} as ${pascal(node.name)}`);
  output.set('types/__init__.py', typeInit.finish());

  const account = accounts[0];
  requireCondition(account.data.kind === 'structTypeNode', 'Channel must be a struct');
  requireCondition(fixedSize(account.data, definitions) === 256, 'Channel must occupy 256 bytes');
  const accountTagType = definitions.get('accountDiscriminator')?.type;
  requireCondition(accountTagType?.kind === 'enumTypeNode', 'missing account discriminator enum');
  const accountTag = enumVariants(accountTagType).find((entry) => entry.name === 'Channel')?.value;
  requireCondition(accountTag !== undefined, 'missing Channel account discriminator');
  const first = account.data.fields?.[0];
  requireCondition(first?.name === 'discriminator' && first.type.kind === 'numberTypeNode' && first.type.format === 'u8' && first.type.endian === 'le', 'Channel requires a leading u8 discriminator');
  const accountModule = new PythonModule();
  accountModule.use('pydantic', 'Field');
  accountModule.use('typing', 'Self');
  accountModule.use('solana.rpc.async_api', 'AsyncClient');
  accountModule.use('solana.rpc.commitment', 'Commitment');
  accountModule.use('solders.pubkey', 'Pubkey');
  for (const name of ['WireModel', 'fetch_account', 'fetch_accounts']) accountModule.use(RUNTIME, name);
  accountModule.use('..program_id', PROGRAM_ADDRESS);
  const accountFields = fields(account.data, accountModule, definitions, '..types.');
  accountModule.use('typing', 'Annotated');
  accountModule.use('pyborsh', 'U8');
  accountFields[0] = `    discriminator: Annotated[int, U8, Field(ge=${accountTag}, le=${accountTag})] = ${accountTag}`;
  accountModule.lines.push('class Channel(WireModel):', '    """Channel account including its leading account discriminator."""', '', ...accountFields, '', '    @classmethod', '    def decode(cls, data: bytes) -> Self:', '        """Decode and validate the complete account bytes."""', '        return cls.from_borsh(data)', '', '    @classmethod', '    async def fetch(', '        cls,', '        conn: AsyncClient,', '        address: Pubkey,', '        commitment: Commitment | None = None,', `        program_id: Pubkey = ${PROGRAM_ADDRESS},`, '    ) -> Self | None:', '        """Fetch one account and verify its owner and wire data."""', '        return await fetch_account(cls, conn, address, commitment, program_id)', '', '    @classmethod', '    async def fetch_multiple(', '        cls,', '        conn: AsyncClient,', '        addresses: list[Pubkey],', '        commitment: Commitment | None = None,', `        program_id: Pubkey = ${PROGRAM_ADDRESS},`, '    ) -> list[Self | None]:', '        """Fetch ordered accounts, preserving missing account positions."""', '        return await fetch_accounts(cls, conn, addresses, commitment, program_id)');
  output.set('accounts/channel.py', accountModule.finish());
  output.set('accounts/__init__.py', `${HEADER}from .channel import Channel as Channel\n`);

  for (const node of instructions) output.set(`instructions/${node.name}.py`, instruction(node, definitions));
  const instructionTags = instructions.map((node) => JSON.stringify(node.arguments?.[0].defaultValue));
  requireCondition(new Set(instructionTags).size === instructions.length, 'duplicate instruction discriminators');
  const instructionInit = new PythonModule();
  for (const node of instructions) {
    const name = pascal(node.name);
    instructionInit.use(`.${node.name}`, `${name} as ${name}`);
    instructionInit.use(`.${node.name}`, `${name}Accounts as ${name}Accounts`);
    if ((node.arguments ?? []).length > 1) instructionInit.use(`.${node.name}`, `${name}Args as ${name}Args`);
  }
  output.set('instructions/__init__.py', instructionInit.finish());

  const pda = pdas[0];
  requireCondition(pda.seeds?.length === 1, 'event authority requires one seed');
  const seed = pda.seeds[0];
  requireCondition(seed.kind === 'constantPdaSeedNode' && seed.type.kind === 'stringTypeNode' && seed.type.encoding === 'utf8' && seed.value.kind === 'stringValueNode', 'unsupported PDA seed');
  requireCondition(new TextEncoder().encode(seed.value.string).length <= 32, 'PDA seed exceeds 32 bytes');
  output.set('pdas/index.py', `${HEADER}from solders.pubkey import Pubkey\n\nfrom ..program_id import ${PROGRAM_ADDRESS}\n\n\ndef find_event_authority_pda(\n    program_id: Pubkey = ${PROGRAM_ADDRESS},\n) -> tuple[Pubkey, int]:\n    """Derive the event authority for the selected program."""\n    return Pubkey.find_program_address([bytes.fromhex(${literal(Buffer.from(seed.value.string, 'utf8').toString('hex'))})], program_id)\n`);
  output.set('pdas/__init__.py', `${HEADER}from .index import find_event_authority_pda as find_event_authority_pda\n`);

  for (const event of events) {
    requireCondition(event.data.kind === 'hiddenPrefixTypeNode' && event.data.prefix?.length === 1 && event.data.type.kind === 'structTypeNode', `${event.name}: unsupported event shape`);
    requireCondition(!(event.data.type.fields ?? []).some((field) => field.name === 'discriminator'), `${event.name}: field discriminator collides with the generated event prefix`);
    const prefix = event.data.prefix[0];
    requireCondition(prefix.type.kind === 'fixedSizeTypeNode' && prefix.type.size === 8 && prefix.type.type.kind === 'bytesTypeNode' && prefix.value.kind === 'bytesValueNode' && prefix.value.encoding === 'base16' && /^[a-fA-F0-9]{16}$/.test(prefix.value.data), `${event.name}: unsupported event prefix`);
    const marker = event.discriminators?.[0];
    requireCondition(event.discriminators?.length === 1 && marker?.kind === 'constantDiscriminatorNode' && marker.offset === 0 && JSON.stringify(marker.constant) === JSON.stringify(prefix), `${event.name}: event prefix/discriminator mismatch`);
    const module = new PythonModule();
    module.use('typing', 'Annotated');
    module.use('pyborsh', 'Bytes');
    module.use('pydantic', 'Field');
    module.use('pydantic', 'field_validator');
    module.use(RUNTIME, 'WireModel');
    const name = pascal(event.name);
    module.lines.push(`DISCRIMINATOR = bytes.fromhex(${literal(prefix.value.data)})`, '', '', `class ${name}(WireModel):`, `    """${name} event including its constant wire prefix."""`, '', '    discriminator: Annotated[bytes, Bytes(8), Field(min_length=8, max_length=8, exclude=True, repr=False)] = (', '        DISCRIMINATOR', '    )', ...fields(event.data.type, module, definitions, '..types.'), '', '    @field_validator("discriminator")', '    @classmethod', '    def _validate_discriminator(cls, value: bytes) -> bytes:', '        if value != DISCRIMINATOR:', '            raise ValueError("Invalid event discriminator")', '        return value');
    output.set(`events/${event.name}.py`, module.finish());
  }
  const eventInit = new PythonModule();
  for (const node of events) eventInit.use(`.${node.name}`, `${pascal(node.name)} as ${pascal(node.name)}`);
  output.set('events/__init__.py', eventInit.finish());

  const errorModule = new PythonModule();
  errorModule.use(RUNTIME, 'ProgramError');
  errorModule.use('collections.abc', 'Callable');
  requireCondition(new Set(errors.map((error) => error.code)).size === errors.length, 'duplicate error codes');
  errorModule.lines.push('class CustomError(ProgramError):', '    """Base class for PaymentChannels custom errors."""', '', '');
  for (const error of errors) {
    requireCondition(Number.isSafeInteger(error.code) && error.code >= 0 && error.code <= 0xffffffff && typeof error.message === 'string', `invalid error ${error.name}`);
    const name = pascal(error.name);
    requireCondition(!['Callable', 'CustomError', 'ProgramError'].includes(name), `${error.name}: error class ${name} collides with a generated module symbol`);
    errorModule.lines.push(`class ${name}(CustomError):`, `    """IDL error ${error.code}: ${name}."""`, '', `    code = ${error.code}`, `    name = ${literal(name)}`, `    msg = ${literal(error.message)}`, '', '    def __init__(self, logs: list[str] | None = None) -> None:', '        super().__init__(self.code, self.msg, logs)', '', '');
  }
  errorModule.lines.push('CUSTOM_ERROR_MAP: dict[int, Callable[[list[str] | None], CustomError]] = {', ...errors.map((error) => `    ${error.code}: ${pascal(error.name)},`), '}', '', '', 'def from_code(code: int, logs: list[str] | None = None) -> CustomError | None:', '    """Create an independent exception for a recognized program code."""', '    error_type = CUSTOM_ERROR_MAP.get(code)', '    return None if error_type is None else error_type(logs)');
  output.set('errors/paymentChannels.py', errorModule.finish());
  const errorInit = new PythonModule();
  errorInit.use('solana.rpc.core', 'RPCException');
  errorInit.use('solders.pubkey', 'Pubkey');
  errorInit.use(RUNTIME, 'program_error_code');
  errorInit.use('..program_id', PROGRAM_ADDRESS);
  errorInit.use('.paymentChannels', 'CustomError');
  errorInit.use('.paymentChannels', 'from_code');
  errorInit.lines.push('def from_tx_error(', '    error: RPCException,', `    program_id: Pubkey = ${PROGRAM_ADDRESS},`, ') -> CustomError | None:', '    """Decode a custom error only when the failing program matches."""', '    extracted = program_error_code(error, program_id)', '    if extracted is None:', '        return None', '    return from_code(extracted[0], extracted[1])');
  output.set('errors/__init__.py', errorInit.finish());
  return new Map([...output].sort(([a], [b]) => a.localeCompare(b)));
}
