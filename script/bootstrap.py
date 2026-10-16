#!/usr/bin/env python3
"""Fetch pinned upstream runtimes/models and build the local denoiser libraries.

All toolchains and caches stay in this workspace. No audio is uploaded.
"""
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache"
LIB = ROOT / "Vendor/Sherpa/lib"
MODELS = ROOT / "Resources/Models"
DF_REV = "d375b2d8309e0935d165700c91da9de862a99c31"
HUSH_REV = "9f6414e91461a8f4bdf9840c0cdcdcb7da986339"


def run(*args, cwd=ROOT, env=None):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)


def fetch(url, name, checksum=None):
    destination = CACHE / name
    if not destination.exists():
        print(f"Downloading {name}", flush=True)
        temporary = destination.with_suffix(destination.suffix + ".partial")
        # Git for Windows ships OpenSSL curl with its CA bundle. Prefer it over
        # Schannel curl on build runners whose certificate-revocation host is offline.
        # Certificate and host verification stay enabled with either implementation.
        git_curl = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/mingw64/bin/curl.exe"
        curl = git_curl if os.name == "nt" and git_curl.exists() else "curl"
        run(curl, "-fL", "--retry", "3", "--retry-all-errors", "--silent", "--show-error", url, "-o", temporary)
        temporary.replace(destination)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    if checksum and digest != checksum:
        raise RuntimeError(f"Checksum mismatch: {name}; remove {destination} and retry")
    return destination


def extract(archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as tf:
        # Only upstream source/runtime archives; reject paths outside the destination.
        for member in tf.getmembers():
            if not (destination / member.name).resolve().is_relative_to(destination.resolve()):
                raise RuntimeError("Unsafe archive path")
        tf.extractall(destination, filter="data")


def rust_environment():
    cargo = CACHE / "cargo/bin/cargo"
    env = dict(os.environ, CARGO_HOME=str(CACHE / "cargo"), RUSTUP_HOME=str(CACHE / "rustup"),
               MACOSX_DEPLOYMENT_TARGET="14.2", CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS="fallback",
               CARGO_PROFILE_RELEASE_STRIP="none")
    env["PATH"] = str(cargo.parent) + os.pathsep + env["PATH"]
    if not cargo.exists():
        installer = fetch("https://static.rust-lang.org/rustup/archive/1.29.1/aarch64-apple-darwin/rustup-init", "rustup-init",
                          "ec1b9233e7f72990ecd8e62063fa7f6c3dfc2bec8e97f88bff165f9100ac696a")
        installer.chmod(0o755)
        run(installer, "-y", "--no-modify-path", "--profile", "minimal", "--default-toolchain", "1.90.0", env=env)
    return cargo, env


def main():
    if platform.machine() != "arm64":
        raise RuntimeError("This development build currently targets Apple Silicon Macs.")
    CACHE.mkdir(exist_ok=True)
    LIB.mkdir(parents=True, exist_ok=True)
    MODELS.mkdir(parents=True, exist_ok=True)
    sherpa = fetch(
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/"
        "sherpa-onnx-v1.13.8-osx-arm64-shared-lib.tar.bz2",
        "sherpa-1.13.8-arm64.tar.bz2",
        "ae77050cdae565496059d96f5ab33d77b397a0864282a4e4a26e3b3b3effb948",
    )
    if not (LIB / "libsherpa-onnx-c-api.dylib").exists():
        extract(sherpa, CACHE / "sherpa")
        for path in (CACHE / "sherpa/sherpa-onnx-v1.13.8-osx-arm64-shared-lib/lib").glob("*.dylib"):
            shutil.copy2(path, LIB / path.name)
    dpdf = fetch(
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speech-enhancement-models/"
        "dpdfnet2_48khz_hr.onnx", "dpdfnet2_48khz_hr.onnx",
        "0b399f8a58dc4d70d8cd97541f5c39869406145193b957d00a03b66070944928",
    )
    shutil.copy2(dpdf, MODELS / dpdf.name)
    # Automatic foreground speech enhancement replaces voice-profile matching.
    (MODELS / "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx").unlink(missing_ok=True)
    hush_model = fetch(
        "https://huggingface.co/weya-ai/hush/resolve/a55d932cbf6344d284ac985f21e7f6e5bc4d38a5/"
        "onnx/advanced_dfnet16k_model_best_onnx.tar.gz", "hush-model.tar.gz",
        "45632ccaa82b71bb743d6caa7c78e983fe2f2790a3af7f6ec48e6ed7ba085df6",
    )
    shutil.copy2(hush_model, MODELS / "hush-main-speaker.tar.gz")
    if not (LIB / "libweya_nc.dylib").exists():
        hush = fetch(f"https://codeload.github.com/pulp-vision/Hush/tar.gz/{HUSH_REV}", "hush-source.tar.gz",
                     "1eee4b2f44b2e1d75aed3bc7f5be7c33238629c6862f19ae022ad45671cb49c2")
        extract(hush, ROOT / "Vendor/Hush")
        source = ROOT / f"Vendor/Hush/Hush-{HUSH_REV}/native/weya_nc_build/weya_nc"
        cargo, env = rust_environment()
        run(cargo, "build", "--release", "--locked", cwd=source, env=env)
        shutil.copy2(source / "target/release/libweya_nc.dylib", LIB / "libweya_nc.dylib")

    if not (LIB / "librnnoise.dylib").exists():
        rn_rev = "70f1d256acd4b34a572f999a05c87bf00b67730d"
        rn = fetch(f"https://codeload.github.com/xiph/rnnoise/tar.gz/{rn_rev}", "rnnoise-source.tar.gz",
                   "f61ee0b3f4c4cd337303e003d333357c5eaf25ef5d75a742109ee59e9a0a3932")
        extract(rn, ROOT / "Vendor/RNNoise")
        source = ROOT / f"Vendor/RNNoise/rnnoise-{rn_rev}"
        model_hash = (source / "model_version").read_text().strip()
        weights = fetch(f"https://media.xiph.org/rnnoise/models/rnnoise_data-{model_hash}.tar.gz", "rnnoise-weights.tar.gz", model_hash)
        extract(weights, source)
        files = ["denoise", "rnn", "pitch", "kiss_fft", "celt_lpc", "nnet", "nnet_default",
                 "parse_lpcnet_weights", "rnnoise_data", "rnnoise_tables"]
        run("xcrun", "clang", "-O3", "-dynamiclib", "-mmacosx-version-min=14.2",
            "-I", source / "include", "-I", source / "src", "-DRNNOISE_BUILD",
            *[source / f"src/{name}.c" for name in files], "-o", LIB / "librnnoise.dylib")

    if not (LIB / "libdf.dylib").exists():
        df = fetch(f"https://codeload.github.com/Rikorose/DeepFilterNet/tar.gz/{DF_REV}", "deepfilternet-source.tar.gz",
                   "49471f3633a24c097d82f3b0d2dbd83a0c1bac3e2f6f6c9a675ef0020ebe5c51")
        source = ROOT / f"Vendor/DeepFilterNet/DeepFilterNet-{DF_REV}"
        if not source.exists():
            extract(df, ROOT / "Vendor/DeepFilterNet")
        cargo, env = rust_environment()
        pinned_lock = ROOT / "Vendor/DeepFilterNet.Cargo.lock"
        lock_flags = []
        if pinned_lock.exists():
            shutil.copy2(pinned_lock, source / "Cargo.lock")
            lock_flags = ["--locked"]
        run(cargo, "build", "-p", "deep_filter", "--lib", "--release", *lock_flags,
            "--no-default-features", "--features", "capi", cwd=source, env=env)
        if not pinned_lock.exists():
            shutil.copy2(source / "Cargo.lock", pinned_lock)
        shutil.copy2(source / "target/release/libdf.dylib", LIB / "libdf.dylib")
    # DF's official C API loads a model archive; use the archive from the same pinned revision.
    df_source = ROOT / f"Vendor/DeepFilterNet/DeepFilterNet-{DF_REV}"
    df_model = df_source / "models/DeepFilterNet3_onnx.tar.gz"
    if not df_model.exists():
        model = fetch(f"https://raw.githubusercontent.com/Rikorose/DeepFilterNet/{DF_REV}/models/DeepFilterNet3_onnx.tar.gz", "DeepFilterNet3_onnx.tar.gz")
        shutil.copy2(model, MODELS / "DeepFilterNet3_onnx.tar.gz")
    else:
        shutil.copy2(df_model, MODELS / df_model.name)

    manifest = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in [*LIB.glob("*.dylib"), *MODELS.glob("*")] if p.is_file()}
    (CACHE / "dependency-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("All three noise engines and the automatic main-speaker filter are ready.", flush=True)


if __name__ == "__main__":
    main()
