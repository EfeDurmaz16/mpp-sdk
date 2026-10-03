import { defineConfig } from "vitest/config";
import base from "./vitest.config";
import { pureTestFiles } from "./vitest.pure.config";

// Preserve the base selector and serial execution for every remaining file,
// including newly added tests. The on-chain suite keeps its dedicated config.
export default defineConfig({
  ...base,
  test: {
    ...base.test,
    exclude: [...base.test!.exclude!, ...pureTestFiles],
  },
});
