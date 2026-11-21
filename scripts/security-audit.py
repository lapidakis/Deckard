#!/usr/bin/env python3
"""Check public Package.resolved revisions against OSV; never upload source.

Usage: python3 scripts/security-audit.py [--output /tmp/deckard-osv.json]
Requires Python 3 and network access. Exit 0: no matches; 1: advisories;
2: incomplete scan. A clean scan is limited to OSV's commit coverage.
"""
import argparse
import datetime
import json
from pathlib import Path
import sys
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        lock = Path(__file__).resolve().parent.parent / "Package.resolved"
        pins = json.loads(lock.read_text())["pins"]
        request = urllib.request.Request(
            "https://api.osv.dev/v1/querybatch",
            data=json.dumps({"queries": [{"commit": p["state"]["revision"]} for p in pins]}).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            results = json.load(response)["results"]
        if len(results) != len(pins) or any(r.get("next_page_token") for r in results):
            raise ValueError("OSV response is incomplete; investigate manually")
        report = {
            "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "method": "OSV querybatch by pinned public Git commit",
            "packages": [
                {"name": p["identity"], "version": p["state"].get("version"),
                 "revision": p["state"]["revision"], "url": p["location"],
                 "advisories": r.get("vulns", [])}
                for p, r in zip(pins, results)
            ],
        }
        if args.output:
            args.output.write_text(json.dumps(report, indent=2) + "\n")
        affected = [p for p in report["packages"] if p["advisories"]]
        print(f"Checked {len(pins)} pinned commits; {len(affected)} packages have OSV matches.")
        for package in affected:
            print(package["name"], package["version"], ", ".join(v["id"] for v in package["advisories"]))
        return 1 if affected else 0
    except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
        print(f"Security scan incomplete: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
