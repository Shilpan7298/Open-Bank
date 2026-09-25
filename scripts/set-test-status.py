#!/usr/bin/env python3
"""Set the status of tests in tests.json: scripts/set-test-status.py passing IG-01 IG-02 ..."""
import json, sys
from pathlib import Path

path = Path(__file__).resolve().parent.parent / "tests.json"
status, ids = sys.argv[1], set(sys.argv[2:])
data = json.loads(path.read_text())
assert status in data["statuses"], f"status must be one of {data['statuses']}"
known = {t["id"] for t in data["tests"]}
missing = ids - known
assert not missing, f"unknown test ids: {sorted(missing)}"
for t in data["tests"]:
    if t["id"] in ids:
        t["status"] = status
path.write_text(json.dumps(data, indent=1) + "\n")
counts = {}
for t in data["tests"]:
    counts[t["status"]] = counts.get(t["status"], 0) + 1
print(counts)
