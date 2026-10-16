"""Give bundled ONNX Runtime a private import name, avoiding Windows' inbox ORT.

Only the PE import-name string is changed; no inference code is modified.
The source archive and packaged notices record this Apache-2.0 modification.
"""
from pathlib import Path
import shutil


def isolate_onnx_runtime(runtime: Path):
    original = b"onnxruntime.dll\0"
    replacement = b"noise_ort.dll\0".ljust(len(original), b"\0")
    api = runtime / "sherpa-onnx-c-api.dll"
    contents = api.read_bytes()
    if contents.count(original) != 1:
        raise RuntimeError("The pinned sherpa PE import table changed; review the private ORT import patch")
    api.write_bytes(contents.replace(original, replacement))
    shutil.copy2(runtime / "onnxruntime.dll", runtime / "noise_ort.dll")
    (runtime / "onnxruntime.dll").unlink()
    licenses = runtime.parent / "Licenses"; licenses.mkdir(exist_ok=True)
    (licenses / "NATIVE-MODIFICATIONS.txt").write_text(
        "Noise Windows build: sherpa-onnx 1.13.8's PE import name onnxruntime.dll "
        "is changed to noise_ort.dll. The bundled, otherwise unmodified ONNX Runtime "
        "DLL is renamed accordingly. This avoids a collision with Windows' inbox "
        "ONNX Runtime. No inference code or model weights are changed. "
        "Patch source: script/private_windows_runtime.py.\n", encoding="utf-8")
