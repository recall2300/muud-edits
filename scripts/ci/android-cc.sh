#!/usr/bin/env python3
"""Android NDK 의 clang 을 찾아 C 컴파일을 대신 실행한다.

cc 크레이트가 `CC_<target>` 로 이 스크립트를 호출한다. 어떤 타깃용 컴파일러인지는
`CARGO_CFG_TARGET_ARCH`(cargo 가 build script 에 넘겨 주는 값)와
`--target` 인자로 판별한다.

NDK 위치는 다음 순서로 찾는다.
  1. $ANDROID_NDK_HOME, $ANDROID_NDK_ROOT, $ANDROID_NDK_LATEST_HOME
  2. $ANDROID_SDK_ROOT/ndk/<버전>, $ANDROID_HOME/ndk/<버전>
  3. /usr/local/lib/android/sdk/ndk/<버전>  (GitHub Actions 우분투 러너)
"""
from __future__ import annotations

import os
import pathlib
import subprocess
import sys

# Rust 타깃 → (NDK clang 접두어, 기본 API 레벨)
TRIPLES = {
    "aarch64": ("aarch64-linux-android", "aarch64-linux-android"),
    "arm": ("armv7a-linux-androideabi", "armv7-linux-androideabi"),
    "x86_64": ("x86_64-linux-android", "x86_64-linux-android"),
    "x86": ("i686-linux-android", "i686-linux-android"),
}
FALLBACK_API = "26"


def ndk_root() -> pathlib.Path:
    for var in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "ANDROID_NDK_LATEST_HOME"):
        value = os.environ.get(var)
        if value and pathlib.Path(value).is_dir():
            return pathlib.Path(value)
    sdk_candidates = [
        os.environ.get("ANDROID_SDK_ROOT"),
        os.environ.get("ANDROID_HOME"),
        "/usr/local/lib/android/sdk",
        os.path.expanduser("~/Android/Sdk"),
    ]
    for sdk in sdk_candidates:
        if not sdk:
            continue
        ndk_dir = pathlib.Path(sdk) / "ndk"
        if ndk_dir.is_dir():
            versions = sorted(
                (p for p in ndk_dir.iterdir() if p.is_dir()),
                key=lambda p: p.name,
                reverse=True,
            )
            if versions:
                return versions[0]
    sys.exit("android-cc: Android NDK 를 찾지 못했습니다(ANDROID_NDK_HOME 또는 SDK/ndk).")


def arch_of(args: list[str]) -> str:
    # cargo 가 build script 에 넘겨 주는 값이 가장 정확하다.
    cfg_arch = os.environ.get("CARGO_CFG_TARGET_ARCH")
    if cfg_arch in TRIPLES:
        return cfg_arch
    target = os.environ.get("TARGET", "")
    for arch, (_, rust_triple) in TRIPLES.items():
        if rust_triple in target:
            return arch
    for index, arg in enumerate(args):
        if arg == "--target" and index + 1 < len(args):
            triple = args[index + 1].lower()
            for arch, (_, rust_triple) in TRIPLES.items():
                if rust_triple in triple:
                    return arch
        if arg.startswith("--target="):
            triple = arg.split("=", 1)[1].lower()
            for arch, (_, rust_triple) in TRIPLES.items():
                if rust_triple in triple:
                    return arch
    return "aarch64"


def main() -> None:
    args = sys.argv[1:]
    arch = arch_of(args)
    clang_prefix, _ = TRIPLES[arch]
    api = os.environ.get("ANDROID_API_LEVEL", FALLBACK_API)

    bin_dir = ndk_root() / "toolchains" / "llvm" / "prebuilt"
    prebuilt = sorted(bin_dir.glob("*/bin")) if bin_dir.is_dir() else []
    if not prebuilt:
        sys.exit(f"android-cc: NDK 툴체인을 찾지 못했습니다: {bin_dir}")

    # NDK 는 `aarch64-linux-android26-clang` 처럼 API 레벨이 붙은 이름을 쓴다.
    for candidate in (f"{clang_prefix}{api}-clang", f"{clang_prefix}-clang"):
        clang = prebuilt[0] / candidate
        if clang.exists():
            os.execv(str(clang), [str(clang)] + args)
    sys.exit(f"android-cc: {clang_prefix}-clang 을 찾지 못했습니다: {prebuilt[0]}")


if __name__ == "__main__":
    main()
