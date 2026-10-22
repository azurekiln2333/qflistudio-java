"""Prove Java generation preserves every unrelated record and metadata field."""
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[4]
CORE = ROOT.parent / "qfli_studio_core"
REPORT = pathlib.Path(__file__).with_name("java-generation-preservation.json")

def snapshot():
    records = {}
    for name in ("tutorials", "examples"):
        document = json.loads((CORE / f"assets/content/{name}.json").read_text(encoding="utf-8"))
        other = [entry for entry in document["entries"] if entry["language"] != "java"]
        metadata = {key: value for key, value in document.items() if key not in ("entries", "updatedAt")}
        canonical = json.dumps({"entries": other, "metadata": metadata}, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        records[name] = {"unrelatedCount": len(other), "unrelatedAndMetadataSha256": hashlib.sha256(canonical.encode()).hexdigest(), "javaCount": sum(e["language"] == "java" for e in document["entries"])}
    return records

if sys.argv[1] == "before":
    REPORT.write_text(json.dumps({"before": snapshot()}, indent=2), encoding="utf-8")
else:
    report = json.loads(REPORT.read_text(encoding="utf-8"))
    report["after"] = snapshot()
    report["unchanged"] = all(report["before"][key]["unrelatedAndMetadataSha256"] == report["after"][key]["unrelatedAndMetadataSha256"] for key in report["before"])
    REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    raise SystemExit(not report["unchanged"])
