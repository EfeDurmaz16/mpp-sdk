"""Gate line coverage globally and line/branch coverage per native client file."""

import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
assert report["totals"]["percent_statements_covered"] >= 90, "SDK line coverage is below 90%"
native = {
    name: entry["summary"]
    for name, entry in report["files"].items()
    if name.endswith("_paycore/program_client.py") or "/programs/paymentchannels/" in name
}
assert any(name.endswith("_paycore/program_client.py") for name in native), "Native runtime is absent from coverage"
for name, summary in native.items():
    assert "num_branches" in summary, "Run pytest with --cov-branch"
    lines = summary["percent_statements_covered"]
    branches = summary["covered_branches"] / summary["num_branches"] * 100 if summary["num_branches"] else 100
    assert lines >= 90 and branches >= 90, f"{name}: {lines:.1f}% lines, {branches:.1f}% branches"
print(f"Native per-file coverage gate passed for {len(native)} files.")
