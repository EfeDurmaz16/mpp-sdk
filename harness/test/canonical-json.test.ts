import { describe, expect, it } from "vitest";
import { chargeCanonicalJsonVectors } from "../src/contracts";
import { base64UrlFromUtf8, canonicalizeJson } from "../src/conformance/jcs";

/**
 * RFC 8785 (JCS) reference vectors. The encoder lives in
 * src/conformance/jcs.ts so the standalone vector test here and the
 * cross-SDK conformance runner share one source of truth.
 */
describe("RFC 8785 canonical JSON vectors", () => {
  for (const vector of chargeCanonicalJsonVectors) {
    it(`${vector.id}: canonical JSON before base64url`, () => {
      const canonicalJson = canonicalizeJson(vector.value);

      expect(canonicalJson).toBe(vector.canonicalJson);
      expect(base64UrlFromUtf8(canonicalJson)).toBe(vector.base64Url);
    });
  }

  it("rejects lone surrogates per RFC 8785 sec 3.2.2", () => {
    const lone = String.fromCharCode(0xd834);
    expect(() => canonicalizeJson({ k: lone })).toThrow(/lone surrogate/);
  });

  it("rejects NaN and Infinity per RFC 8785 sec 3.2.2.3", () => {
    expect(() => canonicalizeJson(Number.NaN)).toThrow();
    expect(() => canonicalizeJson(Number.POSITIVE_INFINITY)).toThrow();
  });
});
