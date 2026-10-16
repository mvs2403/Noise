#!/usr/bin/env python3
"""Record the exact desktop build commit and every shipped runtime/model hash."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def digest(path):
    with path.open("rb") as stream: return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True)
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    version = (root / "VERSION").read_text().strip()
    native = {p.relative_to(args.stage).as_posix(): digest(p)
              for folder in ("Runtime", "Models", "Licenses")
              for p in sorted((args.stage / folder).rglob("*")) if p.is_file()}
    artifacts = {p.name: {"sha256": digest(p), "bytes": p.stat().st_size}
                 for p in sorted(args.output.iterdir()) if p.is_file() and p.suffix in (".exe", ".zip", ".gz", ".deb")}
    manifest = {"version": version, "platform": args.platform, "commit": commit,
                "signing": "unsigned" if args.platform.startswith("windows") else "not signed",
                "verification": ["four native engines", "bounded queue", "exact bypass", "GUI launch"],
                "runtime_and_models": native, "artifacts": artifacts}
    (args.output / ("release-manifest-" + args.platform + ".json")).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__": main()
