#!/usr/bin/env python3
"""Android NDK 의 llvm-ar 을 찾아 실행한다(cc 크레이트의 `AR_<target>`)."""
from __future__ import annotations

import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from importlib.machinery import SourceFileLoader  # noqa: E402

_cc = SourceFileLoader(
    "android_cc", str(pathlib.Path(__file__).resolve().parent / "android-cc.sh")
).load_module()


def main() -> None:
    bin_dir = _cc.ndk_root() / "toolchains" / "llvm" / "prebuilt"
    prebuilt = sorted(bin_dir.glob("*/bin")) if bin_dir.is_dir() else []
    if not prebuilt:
        sys.exit(f"android-ar: NDK 툴체인을 찾지 못했습니다: {bin_dir}")
    for name in ("llvm-ar",):
        tool = prebuilt[0] / name
        if tool.exists():
            os.execv(str(tool), [str(tool)] + sys.argv[1:])
    sys.exit(f"android-ar: llvm-ar 을 찾지 못했습니다: {prebuilt[0]}")


if __name__ == "__main__":
    main()
