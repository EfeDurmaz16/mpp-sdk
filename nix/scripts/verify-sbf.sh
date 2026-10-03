#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import hashlib
import os
from pathlib import Path
import re

expected = os.environ.get("EXPECTED_SBF_SHA256", "")
if not re.fullmatch(r"[0-9a-f]{64}", expected):
    raise SystemExit("Missing SBF digest from the producer's job output")
path = Path(".nix-artifacts/sbf/payment_channels.so")
if path.is_symlink() or not path.is_file():
    raise SystemExit("Missing regular SBF artifact")
actual = hashlib.sha256(path.read_bytes()).hexdigest()
if actual != expected:
    raise SystemExit("SBF artifact digest does not match the producer")
print(f"Verified payment_channels.so: {actual}")
PY
