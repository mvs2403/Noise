#!/usr/bin/env python3
"""Build the shared desktop DSP with pinned, checksum-verified upstream inputs.

Windows: run in an x64 Visual Studio build environment with Rust 1.90 and CMake.
Outputs are isolated from the macOS development runtimes.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import json
import xml.etree.ElementTree as ET
import tomllib
from bootstrap import ROOT, CACHE, fetch, extract, DF_REV, HUSH_REV
from private_windows_runtime import isolate_onnx_runtime

RN_REV = "70f1d256acd4b34a572f999a05c87bf00b67730d"
SHERPA_WIN = "sherpa-onnx-v1.13.8-win-x64-shared-MT-Release-no-tts-lib"


def run(*args, cwd=ROOT, env=None):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)


def prepare_sources():
    pins = [
        ("rnnoise", "xiph/rnnoise", RN_REV, "f61ee0b3f4c4cd337303e003d333357c5eaf25ef5d75a742109ee59e9a0a3932"),
        ("deepfilternet", "Rikorose/DeepFilterNet", DF_REV, "49471f3633a24c097d82f3b0d2dbd83a0c1bac3e2f6f6c9a675ef0020ebe5c51"),
        ("hush", "pulp-vision/Hush", HUSH_REV, "1eee4b2f44b2e1d75aed3bc7f5be7c33238629c6862f19ae022ad45671cb49c2"),
    ]
    source_root = CACHE / "desktop-sources"
    for name, repo, rev, digest in pins:
        source = source_root / f"{repo.split('/')[-1]}-{rev}"
        if not source.exists():
            extract(fetch(f"https://codeload.github.com/{repo}/tar.gz/{rev}", f"{name}-source.tar.gz", digest), source_root)
    rn = source_root / f"rnnoise-{RN_REV}"
    model_hash = (rn / "model_version").read_text().strip()
    if not (rn / "src/rnnoise_data.c").exists():
        extract(fetch(f"https://media.xiph.org/rnnoise/models/rnnoise_data-{model_hash}.tar.gz", "rnnoise-weights.tar.gz", model_hash), rn)
    df = source_root / f"DeepFilterNet-{DF_REV}"
    shutil.copy2(ROOT / "Vendor/DeepFilterNet.Cargo.lock", df / "Cargo.lock")
    hush = source_root / f"Hush-{HUSH_REV}/native/weya_nc_build/weya_nc"
    return rn, df, hush


def models_and_licenses(output, rn, df, hush):
    models = output / "Models"; models.mkdir(parents=True, exist_ok=True)
    dpdf = fetch("https://github.com/k2-fsa/sherpa-onnx/releases/download/speech-enhancement-models/dpdfnet2_48khz_hr.onnx", "dpdfnet2_48khz_hr.onnx", "0b399f8a58dc4d70d8cd97541f5c39869406145193b957d00a03b66070944928")
    main = fetch("https://huggingface.co/weya-ai/hush/resolve/a55d932cbf6344d284ac985f21e7f6e5bc4d38a5/onnx/advanced_dfnet16k_model_best_onnx.tar.gz", "hush-model.tar.gz", "45632ccaa82b71bb743d6caa7c78e983fe2f2790a3af7f6ec48e6ed7ba085df6")
    shutil.copy2(dpdf, models / dpdf.name); shutil.copy2(main, models / "hush-main-speaker.tar.gz")
    shutil.copy2(df / "models/DeepFilterNet3_onnx.tar.gz", models / "DeepFilterNet3_onnx.tar.gz")
    licenses = output / "Licenses"; licenses.mkdir(exist_ok=True)
    for path in (ROOT / "Vendor/Sherpa").glob("LICENSE-*"): shutil.copy2(path, licenses / path.name)
    shutil.copy2(rn / "COPYING", licenses / "RNNoise-COPYING")
    for path in df.glob("LICENSE*"): shutil.copy2(path, licenses / ("DeepFilterNet-" + path.name))
    shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", licenses / "THIRD_PARTY_NOTICES.md")
    for path in (ROOT / "Desktop/Licenses").glob("*"):
        if path.is_file(): shutil.copy2(path, licenses / path.name)
    # Native Rust dependencies' license texts accompany the complete source archives.
    shutil.copy2(ROOT / "Desktop/packages.lock.json", licenses / "NuGet-packages.lock.json")
    collect_nuget_notices(licenses)


def collect_nuget_notices(destination):
    """Retain package-supplied licenses/notices and MIT copyright metadata."""
    packages = json.loads((ROOT / "Desktop/packages.lock.json").read_text())["dependencies"]["net10.0"]
    cache = Path(os.environ.get("NUGET_PACKAGES", str(Path.home() / ".nuget/packages")))
    mit = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the \"Software\"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
"""
    notices = []
    for name, package in packages.items():
        directory = cache / name.lower() / package["resolved"]
        spec = ET.parse(directory / (name.lower() + ".nuspec")).getroot()
        metadata = {e.tag.split("}")[-1]: e for e in spec.find("{*}metadata")}
        def value(key):
            return metadata[key].text or "" if key in metadata else ""
        notices.append(f"{name} {package['resolved']}\n{value('copyright') or value('authors')}\nLicense: {value('license')}\n{value('projectUrl')}\n")
        if value("license") == "MIT": notices.append(mit)
        for path in directory.iterdir():
            if path.is_file() and any(term in path.name.lower() for term in ("license", "notice", "copying")):
                shutil.copy2(path, destination / (name + "-" + path.name))
    (destination / "NuGet-NOTICES.txt").write_text("\n".join(notices), encoding="utf-8")


def collect_rust_notices(destination, lockfiles):
    selected = set()
    for lock in lockfiles:
        for package in tomllib.loads(lock.read_text(encoding="utf-8"))["package"]:
            if package.get("source", "").startswith("registry+"):
                selected.add((package["name"], package["version"]))
    cargo_home = Path(os.environ.get("CARGO_HOME", str(Path.home() / ".cargo")))
    notices = []
    for manifest in (cargo_home / "registry/src").glob("index.crates.io-*/*/Cargo.toml"):
        package = tomllib.loads(manifest.read_text(encoding="utf-8"))["package"]
        if (package["name"], package["version"]) not in selected: continue
        identity = package["name"] + "-" + package["version"]
        notices.append(identity + "\n" + str(package.get("license", "See bundled license")) + "\n" + str(package.get("authors", [])) + "\n")
        for path in manifest.parent.iterdir():
            if path.is_file() and any(term in path.name.lower() for term in ("license", "licence", "notice", "copying", "copyright")):
                folder = destination / "Rust" / identity; folder.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, folder / path.name)
    (destination / "Rust-NOTICES.txt").write_text("\n".join(sorted(notices)), encoding="utf-8")
    sysroot = Path(subprocess.check_output(["rustc", "+1.90.0", "--print", "sysroot"], text=True).strip())
    for path in (sysroot / "share/doc/rust").glob("*"):
        if path.is_file() and any(term in path.name.lower() for term in ("license", "copyright")):
            shutil.copy2(path, destination / ("Rust-" + path.name))


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(); output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    if sys.platform != "win32": raise RuntimeError("Use a native Windows x64 build host for this release")
    if os.environ.get("PROCESSOR_ARCHITECTURE", "").lower() != "amd64": raise RuntimeError("Windows x64 is required")
    CACHE.mkdir(exist_ok=True)
    runtime = output / "Runtime"; runtime.mkdir(exist_ok=True)
    archive = fetch(f"https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/{SHERPA_WIN}.tar.bz2", SHERPA_WIN + ".tar.bz2", "a1253e665c4f236119c443c8932a8acfca32a546c78c05962d483c9a0eae21b7")
    sherpa = CACHE / "desktop-sherpa-win"
    if not sherpa.exists(): extract(archive, sherpa)
    for dll in sherpa.rglob("*.dll"): shutil.copy2(dll, runtime / dll.name)
    isolate_onnx_runtime(runtime)
    rn, df, hush = prepare_sources()
    build = CACHE / "desktop-native-win"
    run("cmake", "-S", ROOT / "Desktop/Native", "-B", build, "-A", "x64", f"-DRNNOISE_SOURCE={rn}")
    run("cmake", "--build", build, "--config", "Release", "--parallel", "2")
    run("cmake", "--install", build, "--config", "Release", "--prefix", runtime)
    env = dict(os.environ, RUSTFLAGS="-C target-feature=+crt-static", CARGO_PROFILE_RELEASE_STRIP="none")
    # Static CRT makes portable packages independent of the Visual C++ installer.
    run("rustup", "toolchain", "install", "1.90.0", "--profile", "minimal")
    env["CARGO_TARGET_DIR"] = str(CACHE / "desktop-rust-win")
    run("cargo", "+1.90.0", "build", "-p", "deep_filter", "--lib", "--release", "--locked", "--no-default-features", "--features", "capi", "--target", "x86_64-pc-windows-msvc", cwd=df, env=env)
    shutil.copy2(Path(env["CARGO_TARGET_DIR"]) / "x86_64-pc-windows-msvc/release/df.dll", runtime / "df.dll")
    run("cargo", "+1.90.0", "build", "--release", "--locked", "--target", "x86_64-pc-windows-msvc", cwd=hush, env=env)
    shutil.copy2(Path(env["CARGO_TARGET_DIR"]) / "x86_64-pc-windows-msvc/release/weya_nc.dll", runtime / "weya_nc.dll")
    models_and_licenses(output, rn, df, hush)
    collect_rust_notices(output / "Licenses", [df / "Cargo.lock", hush / "Cargo.lock"])


if __name__ == "__main__": main()
