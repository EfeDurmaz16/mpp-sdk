"""Extract structured diagnostics and known test outcomes from raw Vitest output."""

import json
import re
import sys
from pathlib import Path

log = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", Path(sys.argv[1]).read_text(errors="replace"))
marker = "[surfnet-diag]"
for line in log.splitlines():
    if marker in line:
        try:
            record = json.loads(line.split(marker, 1)[1].strip())
        except json.JSONDecodeError:
            print("unparseable diagnostic record")
        else:
            print(json.dumps(record, separators=(",", ":")))
    elif "Tests " in line or "Test Files " in line or "Duration " in line:
        # Keep summary counters and duration only; never copy a failed assertion.
        for match in re.findall(r"\b\d+ (?:failed|passed|skipped)\b|\b\d+\.\d+s\b", line):
            print(("file" if "Test Files" in line else "suite") + " " + match)
for label in ("InvalidProgramForExecution", "BlockhashNotFound", "Blockhash not found",
              "ECONNRESET", "UND_ERR_SOCKET", "Too Many Requests", "fetch failed", "not resolved from datasource"):
    if label in log:
        print("observed " + label)
