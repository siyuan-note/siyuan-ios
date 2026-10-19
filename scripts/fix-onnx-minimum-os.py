import os
from pathlib import Path
import plistlib
import re
import subprocess


# Xcode 将静态框架转换为动态框架后，同步实际链接版本，避免沿用上游的最低系统版本。
framework = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["FRAMEWORKS_FOLDER_PATH"] / "onnxruntime.framework"
plist_path = framework / "Info.plist"
info = plistlib.loads(plist_path.read_bytes())
binary = framework / info["CFBundleExecutable"]
build = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
versions = re.findall(r"^\s*minos\s+(\d+(?:\.\d+)*)\s*$", build, re.MULTILINE)
if not versions:
    raise RuntimeError("Cannot determine ONNX Runtime minimum OS version")


def version(value):
    return tuple((list(map(int, value.split("."))) + [0, 0])[:3])


minimum = max(versions, key=version)
if version(minimum) > version(os.environ["IPHONEOS_DEPLOYMENT_TARGET"]):
    raise RuntimeError("ONNX Runtime requires a newer iOS version than the app")
if info.get("MinimumOSVersion") != minimum:
    info["MinimumOSVersion"] = minimum
    plist_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    # 修改嵌入框架后重新签名，主应用由 Xcode 在后续阶段签名。
    if os.environ.get("CODE_SIGNING_ALLOWED") == "YES":
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
        subprocess.run([
            "/usr/bin/codesign", "--force", "--sign", identity,
            "--preserve-metadata=identifier,entitlements,flags", "--timestamp=none", str(framework),
        ], check=True)
print(f"ONNX Runtime MinimumOSVersion verified: {minimum}")
