import { getCompiledTransactionMessageDecoder, getTransactionDecoder } from "@solana/kit";

interface WireSummary {
  version: "legacy" | 0 | 1 | null;
  programIds: string[];
  decodeError?: string;
}

/** Preserve instruction order, including repeated invocations. Only public program IDs leave this function. */
export function decodeWire(encoded: string): WireSummary {
  try {
    const transaction = getTransactionDecoder().decode(Buffer.from(encoded, "base64"));
    const message = getCompiledTransactionMessageDecoder().decode(transaction.messageBytes);
    const indexes = message.version === 1
      ? message.instructionHeaders.map(header => header.programAccountIndex)
      : message.instructions.map(instruction => instruction.programAddressIndex);

    if (indexes.some(index => index >= message.staticAccounts.length)) {
      return { version: message.version, programIds: [], decodeError: "non-static-program-index" };
    }
    return { version: message.version, programIds: indexes.map(index => message.staticAccounts[index]) };
  } catch {
    return { version: null, programIds: [], decodeError: "invalid-wire" };
  }
}
