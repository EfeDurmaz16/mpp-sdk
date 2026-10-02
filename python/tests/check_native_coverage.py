"""Gate SDK lines and per-file line/branch coverage for native clients and signing."""

import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
assert report["totals"]["percent_statements_covered"] >= 90, "SDK line coverage is below 90%"
required = ("_paycore/program_client.py", "_paycore/transaction.py", "solana_pay_kit/signer.py")
native = {
    name: entry["summary"]
    for name, entry in report["files"].items()
    if name.endswith(required) or "/programs/paymentchannels/" in name
}
for suffix in required:
    assert any(name.endswith(suffix) for name in native), f"Required coverage file missing: {suffix}"
project = Path(__file__).resolve().parents[1]
generated = project / "src/solana_pay_kit/protocols/programs/paymentchannels"
for file in generated.rglob("*.py"):
    name = file.relative_to(project).as_posix()
    assert name in native, f"Generated client file missing from coverage: {name}"
for name, summary in native.items():
    assert "num_branches" in summary, "Run pytest with --cov-branch"
    lines = summary["percent_statements_covered"]
    branches = summary["covered_branches"] / summary["num_branches"] * 100 if summary["num_branches"] else 100
    assert lines >= 90 and branches >= 90, f"{name}: {lines:.1f}% lines, {branches:.1f}% branches"
print(f"Native per-file coverage gate passed for {len(native)} files.")
