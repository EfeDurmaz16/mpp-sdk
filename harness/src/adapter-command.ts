import { isAbsolute } from "node:path";
import {
  clientImplementations,
  serverImplementations,
  type ImplementationDefinition,
} from "./implementations";

const variable = "PAY_KIT_HARNESS_COMMANDS";
const knownAdapters = new Set(
  [...clientImplementations, ...serverImplementations].map(
    ({ role, id }) => `${role}:${id}`,
  ),
);

// Build systems can supply prebuilt adapters without changing native commands.
// Values are argv arrays, not shell commands. Missing keys keep native behavior.
export function resolveAdapterCommand(
  implementation: ImplementationDefinition,
  encoded: string | undefined = process.env[variable],
): string[] {
  if (encoded === undefined) return implementation.command;

  let parsed: unknown;
  try {
    parsed = JSON.parse(encoded);
  } catch {
    throw new Error(`${variable} must be a JSON object of adapter argv arrays`);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`${variable} must be a JSON object of adapter argv arrays`);
  }

  const overrides = new Map<string, string[]>();
  for (const [key, argv] of Object.entries(parsed)) {
    if (!knownAdapters.has(key)) {
      throw new Error(`${variable} contains unknown adapter ${key}`);
    }
    if (
      !Array.isArray(argv) ||
      argv.length === 0 ||
      !argv.every(
        (argument): argument is string =>
          typeof argument === "string" && !argument.includes("\0"),
      ) ||
      !isAbsolute(argv[0])
    ) {
      throw new Error(
        `${variable}[${key}] must be an argv array with an absolute executable path`,
      );
    }
    overrides.set(key, argv);
  }

  return (
    overrides.get(`${implementation.role}:${implementation.id}`) ??
    implementation.command
  );
}
