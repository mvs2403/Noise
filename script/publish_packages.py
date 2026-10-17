#!/usr/bin/env python3
"""Mirror verified release installers to GHCR as downloadable OCI artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile


ARTIFACT_TYPE = "application/vnd.noise.installers.v1"
PLATFORMS = {
    "macos-arm64": ("apple-silicon.dmg", "apple-silicon.zip"),
    "windows-x64": ("windows-x64-setup.exe", "windows-x64.zip"),
    "linux-x64": ("linux-x64.deb", "linux-x64.tar.gz"),
}


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def checksums(text):
    result = {}
    for line in text.lstrip("\ufeff").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})\s+\*?([^/\\]+)", line)
        if not match or match[2] in result:
            raise ValueError("Invalid or duplicate release checksum entry")
        result[match[2]] = match[1]
    return result


def validate_asset(path, metadata, expected=None):
    actual = digest(path)
    if (path.stat().st_size != metadata["size"]
            or metadata.get("digest") != "sha256:" + actual
            or (expected is not None and expected != actual)):
        raise ValueError(f"Release asset verification failed: {path.name}")


def prepare(repo, tag, work, assets_dir=None):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("Expected an owner/repository name")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("Expected a version tag such as v0.3.0")
    version = tag[1:]
    release = json.loads(run("gh", "api", f"repos/{repo}/releases/tags/{tag}",
                             capture_output=True).stdout)
    if release["draft"] or release["tag_name"] != tag:
        raise ValueError("Only published releases can be mirrored")
    assets = {item["name"]: item for item in release["assets"]}
    downloaded = work / "download"
    downloaded.mkdir(parents=True, exist_ok=True)

    def fetch(name, expected=None):
        if Path(name).name != name or name not in assets:
            raise ValueError(f"Missing or invalid release asset: {name}")
        path = downloaded / name
        if assets_dir is not None:
            shutil.copyfile(assets_dir / name, path)
        else:
            run("gh", "release", "download", tag, "--repo", repo,
                "--pattern", name, "--dir", str(downloaded), "--clobber")
        validate_asset(path, assets[name], expected)
        return path

    upstream = fetch("SHA256SUMS.txt")
    sums = checksums(upstream.read_text())
    bundles = []
    for platform, suffixes in PLATFORMS.items():
        installers = [f"Noise-{version}-{suffix}" for suffix in suffixes]
        if not any(name in assets for name in installers):
            continue
        manifest_name = f"release-manifest-{platform}.json"
        if manifest_name not in assets:
            manifest_name = "release-manifest.json"
        manifest_path = fetch(manifest_name, sums[manifest_name])
        manifest = json.loads(manifest_path.read_text())
        if manifest["version"] != version:
            raise ValueError("Build manifest version does not match the release")
        if platform == "macos-arm64":
            if manifest.get("architecture") != "arm64":
                raise ValueError("Build manifest architecture mismatch")
        elif manifest.get("platform") != platform:
            raise ValueError("Build manifest platform mismatch")
        commit = manifest["commit"]
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ValueError("Build manifest must identify an exact source commit")
        records = manifest.get("artifacts")
        if records is None:
            records = {item["file"]: item for item in manifest["assets"]}
        sources = [name for name in records if name.endswith("-source.tar.gz")]
        if len(sources) != 1:
            raise ValueError("Build manifest must include one matching source archive")
        source = sources[0]
        bundle = work / platform
        bundle.mkdir(parents=True, exist_ok=False)
        for name in [*installers, source]:
            record = records[name]
            path = fetch(name, sums[name])
            if record["sha256"] != sums[name] or record["bytes"] != path.stat().st_size:
                raise ValueError(f"Build manifest disagrees with release asset: {name}")
            shutil.copyfile(path, bundle / name)
        with tarfile.open(bundle / source) as archive:
            if archive.pax_headers.get("comment") != commit:
                raise ValueError("Source archive does not match the binary build commit")
        shutil.copyfile(manifest_path, bundle / manifest_name)
        shutil.copyfile(upstream, bundle / "UPSTREAM-SHA256SUMS.txt")
        guide = "README.md" if platform == "macos-arm64" else f"docs/{platform.split('-')[0].upper()}.md"
        instructions = {
            "macos-arm64": "Open the DMG and drag Noise.app to Applications. This beta is ad hoc signed and not notarized. The optional virtual microphone driver requires separate setup.",
            "windows-x64": "Run the setup EXE, or extract the portable ZIP and open Noise.exe. This beta is unsigned. Installed virtual audio cables are required; both directions together need two independent cable pairs.",
            "linux-x64": "On Ubuntu 24.04+, install the DEB with sudo apt install ./Noise-*-linux-x64.deb. Alternatively extract the portable archive and run Noise. An existing PulseAudio or PipeWire-Pulse server is required. This beta is unsigned.",
        }
        (bundle / "INSTALL.md").write_text(
            f"# Noise {version} for {platform}\n\n{instructions[platform]}\n\n"
            "These files are the original desktop installers and archives. Install them on the matching operating system.\n\n"
            "Check the downloaded files with `shasum -a 256 -c SHA256SUMS.txt` (macOS) or `sha256sum -c SHA256SUMS.txt` (Linux). On Windows, use `Get-FileHash -Algorithm SHA256` and compare against SHA256SUMS.txt.\n\n"
            f"Setup: https://github.com/{repo}/blob/{commit}/{guide}\n\n"
            f"Release: {release['html_url']}\n\n"
            "The original build manifest and matching source archive are included. License texts remain bundled with the applications and source. UPSTREAM-SHA256SUMS.txt is the original whole-release checksum list; SHA256SUMS.txt covers only this platform bundle.\n",
            encoding="utf-8")
        info = {"schema": 1, "platform": platform, "version": version,
                "source_commit": commit, "release_url": release["html_url"],
                "build_manifest": manifest_name,
                "files": {p.name: {"sha256": digest(p), "bytes": p.stat().st_size}
                          for p in sorted(bundle.iterdir())}}
        (bundle / "bundle-info.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
        (bundle / "SHA256SUMS.txt").write_text(
            "".join(f"{digest(p)}  {p.name}\n" for p in sorted(bundle.iterdir())), encoding="utf-8")
        reference = f"ghcr.io/{repo.split('/')[0].lower()}/noise-{platform}:{version}"
        bundles.append((bundle, reference, commit))
        print(f"Prepared and verified {reference}", flush=True)
    if not bundles:
        raise ValueError("The release has no supported desktop installers")
    return bundles


def publish(bundle, reference, commit, repo, registry_config):
    def oras(*args, **kwargs):
        return subprocess.run(["oras", *args, "--registry-config", str(registry_config)],
                              text=True, **kwargs)

    expected = {p.name: ("sha256:" + digest(p), p.stat().st_size)
                for p in bundle.iterdir()}
    existing = oras("manifest", "fetch", reference, capture_output=True)
    if existing.returncode == 0:
        manifest = json.loads(existing.stdout)
        layers = {item["annotations"]["org.opencontainers.image.title"]:
                  (item["digest"], item["size"]) for item in manifest["layers"]}
        if layers != expected or manifest.get("artifactType") != ARTIFACT_TYPE:
            raise ValueError(f"Refusing to replace an existing version with different files: {reference}")
        print(f"Existing version has identical files: {reference}", flush=True)
    else:
        if "not found" not in existing.stderr.lower() and "404" not in existing.stderr:
            raise RuntimeError(existing.stderr)
        media = {".json": "application/json", ".md": "text/markdown",
                 ".txt": "text/plain", ".zip": "application/zip",
                 ".gz": "application/gzip", ".deb": "application/vnd.debian.binary-package"}
        result = oras("push", reference, "--artifact-type", ARTIFACT_TYPE,
                      "--annotation", f"org.opencontainers.image.source=https://github.com/{repo}",
                      "--annotation", f"org.opencontainers.image.revision={commit}",
                      "--annotation", f"org.opencontainers.image.version={reference.rsplit(':', 1)[1]}",
                      "--annotation", "org.opencontainers.image.description=Original Noise desktop installers, checksums, build manifest and matching source. Retrieve with ORAS and install on the matching OS.",
                      *[f"{name}:{media.get(Path(name).suffix, 'application/octet-stream')}"
                        for name in sorted(expected)], cwd=bundle)
        result.check_returncode()
    descriptor = json.loads(oras("manifest", "fetch", reference, "--descriptor",
                                 capture_output=True, check=True).stdout)
    immutable = reference.rsplit(":", 1)[0] + "@" + descriptor["digest"]
    target = bundle.parent / (bundle.name + "-pulled")
    target.mkdir(exist_ok=False)
    oras("pull", immutable, "--output", str(target), check=True)
    actual = {p.name: ("sha256:" + digest(p), p.stat().st_size) for p in target.iterdir()}
    if actual != expected:
        raise ValueError(f"Registry round-trip verification failed: {reference}")
    print(f"PASS registry download and every file checksum: {immutable}", flush=True)
    # Backfilling an older release must not move the convenient latest alias back.
    repository, version = reference.rsplit(":", 1)
    tags = json.loads(oras("repo", "tags", repository, "--format", "json",
                           capture_output=True, check=True).stdout)["tags"]
    versions = [tuple(map(int, tag.split("."))) for tag in tags
                if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", tag)]
    if tuple(map(int, version.split("."))) == max(versions):
        oras("tag", immutable, "latest", check=True)
    return {"reference": reference, "digest": descriptor["digest"],
            "source_commit": commit, "verified_files": len(expected)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "mvs2403/Noise"))
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--assets-dir", type=Path, help="Verify local release files instead of downloading")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--registry-config", type=Path)
    args = parser.parse_args()
    if not args.prepare_only and args.registry_config is None:
        parser.error("Publishing requires an authenticated --registry-config")
    work = args.work_dir.resolve()
    bundles = prepare(args.repo, args.release_tag, work, args.assets_dir)
    if not args.prepare_only:
        report = [publish(bundle, reference, commit, args.repo, args.registry_config.resolve())
                  for bundle, reference, commit in bundles]
        (work / "publication.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
