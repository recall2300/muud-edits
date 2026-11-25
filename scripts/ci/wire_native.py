#!/usr/bin/env python3
"""`flutter create`로 만든 플랫폼 폴더에 `app/native/`의 네이티브 미디어 엔진을 연결한다.

사용법:

    python3 scripts/ci/prepare_app.py <platforms>     # 플랫폼 폴더 생성
    python3 scripts/ci/wire_native.py android         # 네이티브 연결

이 스크립트는 **CI 전용**이다. 로컬 개발자는 `docs/LOCAL_SETUP.md` 3절처럼
Xcode/Android Studio에서 직접 파일을 추가하는 편이 낫다(디버깅·핫리로드 때문).
CI에는 IDE가 없으므로, 생성된 템플릿 파일을 앵커 기준으로 고쳐 쓴다.

원칙:
* 모든 단계는 여러 번 실행해도 안전하다(이미 적용되어 있으면 건너뛴다).
* 앵커(예: `minSdk = flutter.minSdkVersion`)를 찾지 못하면 **조용히 넘어가지 않고**
  파일 내용을 출력하며 실패한다. 상위 Flutter 템플릿이 바뀌면 여기서 바로 드러나게 하기 위해서다.
"""

from __future__ import annotations

import sys

# Windows 러너의 기본 stdout 은 cp1252 라서 한글 로그가 UnicodeEncodeError 로 죽는다.
# CI 로그를 UTF-8 로 고정한다.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import argparse
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "app"
NATIVE = APP / "native"

# video_player_android(2.13)·media3-exoplayer 가 요구하는 버전과 맞춘다.
# (Transformer 와 common/effect 버전이 어긋나면 런타임에 NoSuchMethodError 가 난다.)
MEDIA3_VERSION = "1.9.2"

# Apple 타깃에 합쳐 넣을 Swift 소스 (의존 순서대로: 모델 → 프로브 → 엔진 → 플러그인)
APPLE_SWIFT = [
    "MuudGraphModels.swift",
    "AVMediaProbe.swift",
    "AVExportEngine.swift",
    "MuudMediaPlugin.swift",
]

MERGE_MARKER = "muud:native-merged"

MERGE_HEADER = f"""
// ─────────────────────────────────────────────────────────────────────────────
// {MERGE_MARKER}
// 아래 코드는 CI에서 `scripts/ci/wire_native.py`가 `app/native/apple/*.swift`를
// 이 파일에 합쳐 넣은 것이다. Xcode 프로젝트(pbxproj)를 건드리지 않고 Runner
// 타깃에 네이티브 미디어 플러그인을 넣기 위한 CI 전용 방식이다.
// 로컬 개발에서는 docs/LOCAL_SETUP.md 3.1/3.2절처럼 파일을 타깃에 직접 추가한다.
// ─────────────────────────────────────────────────────────────────────────────
"""


# ── 공통 유틸 ────────────────────────────────────────────────────────────────


def read(path: pathlib.Path) -> str:
    if not path.exists():
        die(f"파일이 없습니다: {path.relative_to(ROOT)}")
    return path.read_text(encoding="utf-8")


def write(path: pathlib.Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def die(message: str) -> None:
    print(f"❌ {message}", file=sys.stderr)
    sys.exit(1)


def note(message: str) -> None:
    print(f"  • {message}")


def replace_once(path: pathlib.Path, old: str, new: str, *, hint: str = "") -> None:
    """`old`가 정확히 한 번 나오면 바꾼다. 없으면 실패, 여러 번이면 실패."""
    text = read(path)
    count = text.count(old)
    if count == 0:
        die(
            f"{path.relative_to(ROOT)} 에서 예상한 앵커를 찾지 못했습니다.\n"
            f"  찾는 문자열: {old!r}\n"
            f"  힌트: {hint or '상위 Flutter 템플릿이 바뀌었는지 확인하세요.'}\n"
            f"  --- 현재 파일 앞부분 ---\n{text[:1500]}"
        )
    if count > 1:
        die(f"{path.relative_to(ROOT)} 에서 앵커가 {count}번 나옵니다: {old!r}")
    write(path, text.replace(old, new, 1))
    note(f"{path.relative_to(ROOT)} 패치: {old.splitlines()[0][:70]}")


def insert_after(path: pathlib.Path, anchor: str, addition: str) -> None:
    text = read(path)
    if addition.strip() and addition.strip() in text:
        note(f"{path.relative_to(ROOT)} 는 이미 패치되어 있습니다(건너뜀)")
        return
    idx = text.find(anchor)
    if idx < 0:
        die(
            f"{path.relative_to(ROOT)} 에서 앵커를 찾지 못했습니다: {anchor!r}\n"
            f"  --- 현재 파일 앞부분 ---\n{text[:1500]}"
        )
    end = idx + len(anchor)
    write(path, text[:end] + addition + text[end:])
    note(f"{path.relative_to(ROOT)} 패치: {anchor.strip()[:60]} 뒤에 삽입")


def append_block(path: pathlib.Path, block: str, token: str) -> None:
    text = read(path)
    if token in text:
        note(f"{path.relative_to(ROOT)} 는 이미 패치되어 있습니다(건너뜀)")
        return
    write(path, text.rstrip() + "\n\n" + block.strip() + "\n")
    note(f"{path.relative_to(ROOT)} 끝에 블록 추가 ({token})")


def copy_tree(src: pathlib.Path, dst: pathlib.Path, names: list[str]) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for name in names:
        source = src / name
        if not source.exists():
            die(f"네이티브 소스가 없습니다: {source.relative_to(ROOT)}")
        shutil.copy2(source, dst / name)
        note(f"{source.relative_to(ROOT)} → {dst.relative_to(ROOT)}")


# ── Android ─────────────────────────────────────────────────────────────────

ANDROID_APP_LABEL = "muud-edits"
ANDROID_ICON_SIZES = ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"]


def patch_android_branding(android: pathlib.Path) -> None:
    """런처에 보이는 이름과 아이콘을 muud-edits 로 맞춘다(여러 번 실행해도 안전)."""
    manifest = android / "app" / "src" / "main" / "AndroidManifest.xml"
    text = read(manifest)
    if f'android:label="{ANDROID_APP_LABEL}"' not in text:
        if 'android:label="muud_edits"' not in text:
            die(
                f"{manifest.relative_to(ROOT)} 에서 android:label 앵커를 찾지 못했습니다.\n"
                f"  --- 현재 파일 앞부분 ---\n{text[:800]}"
            )
        write(
            manifest,
            text.replace('android:label="muud_edits"', f'android:label="{ANDROID_APP_LABEL}"', 1),
        )
        note(f"{manifest.relative_to(ROOT)} 패치: 앱 이름 {ANDROID_APP_LABEL}")

    res = android / "app" / "src" / "main" / "res"
    for density in ANDROID_ICON_SIZES:
        source = NATIVE / "android" / "icon" / f"mipmap-{density}" / "ic_launcher.png"
        target = res / f"mipmap-{density}" / "ic_launcher.png"
        if not source.exists():
            die(f"앱 아이콘이 없습니다: {source.relative_to(ROOT)}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    note(f"런처 아이콘 교체: {len(ANDROID_ICON_SIZES)}개 밀도")



def patch_android_repositories(android: pathlib.Path) -> None:
    """Maven Central 앞에 Google 미러를 두어 CI 에서의 429(rate limit)를 피한다.

    GitHub Actions 러너가 `repo.maven.apache.org` 에서 429 를 받으면 Gradle 이
    플러그인 해석 단계에서 바로 죽는다. Google이 운영하는 Maven Central 미러를
    먼저 시도하게 하면 이 실패가 사라진다(미러에 없으면 다음 저장소로 넘어간다).
    """
    mirror = '        maven("https://maven-central.storage-download.googleapis.com/maven2/")'

    settings = android / "settings.gradle.kts"
    if mirror in read(settings):
        note(f"{settings.relative_to(ROOT)} 는 이미 미러가 있습니다(건너뜀)")
    else:
        insert_after(
            settings,
            "    includeBuild(\"$flutterSdkPath/packages/flutter_tools/gradle\")\n\n    repositories {\n",
            mirror + "\n",
        )

    root_gradle = android / "build.gradle.kts"
    if mirror in read(root_gradle):
        note(f"{root_gradle.relative_to(ROOT)} 는 이미 미러가 있습니다(건너뜀)")
    else:
        insert_after(
            root_gradle,
            "allprojects {\n    repositories {\n",
            mirror + "\n",
        )


def wire_android() -> None:
    android = APP / "android"
    if not android.is_dir():
        die("app/android 가 없습니다. 먼저 prepare_app.py 를 실행하세요.")

    gradle = android / "app" / "build.gradle.kts"
    text = read(gradle)

    # 1) minSdk 26 — Media3 Transformer와 SAF 경로 처리에 필요.
    if "minSdk = 26" not in text:
        if "minSdk = flutter.minSdkVersion" in text:
            write(gradle, text.replace("minSdk = flutter.minSdkVersion", "minSdk = 26", 1))
            note("minSdk = 26 으로 고정")
        else:
            die(
                "minSdk 앵커(`minSdk = flutter.minSdkVersion`)를 찾지 못했습니다.\n"
                f"  --- {gradle.relative_to(ROOT)} ---\n{text}"
            )

    # 2) Media3 의존성.
    append_block(
        gradle,
        f"""
// muud 미디어 엔진 (Media3 Transformer) — scripts/ci/wire_native.py 가 추가
dependencies {{
    implementation("androidx.media3:media3-transformer:{MEDIA3_VERSION}")
    implementation("androidx.media3:media3-effect:{MEDIA3_VERSION}")
    implementation("androidx.media3:media3-common:{MEDIA3_VERSION}")
}}
""",
        token="media3-transformer",
    )

    # 3) Kotlin 미디어 엔진 소스 (패키지 경로는 앱 applicationId와 무관하게 고정).
    copy_tree(
        NATIVE / "android",
        android / "app" / "src" / "main" / "kotlin" / "com" / "muud" / "edits" / "media",
        ["MuudMediaPlugin.kt", "MediaProbe.kt", "ExportEngine.kt"],
    )

    # 3-b) 앱 이름·런처 아이콘 (템플릿 기본값 대신).
    patch_android_branding(android)

    # 3-c) Maven Central 미러(GitHub 러너가 429 Too Many Requests 를 맞는 경우 대비).
    patch_android_repositories(android)

    # 4) MainActivity 등록.
    main_activity = sorted(
        list((android / "app" / "src" / "main" / "kotlin").glob("**/MainActivity.kt"))
        + list((android / "app" / "src" / "main" / "java").glob("**/MainActivity.kt"))
    )
    if not main_activity:
        die("MainActivity.kt 를 찾지 못했습니다.")
    activity = main_activity[0]
    source = read(activity)
    if "MuudMediaPlugin" in source:
        note(f"{activity.relative_to(ROOT)} 는 이미 패치되어 있습니다(건너뜀)")
        return

    imported = (
        "import com.muud.edits.media.MuudMediaPlugin\n"
        "import io.flutter.embedding.android.FlutterActivity\n"
        "import io.flutter.embedding.engine.FlutterEngine\n"
    )
    if "import io.flutter.embedding.android.FlutterActivity" not in source:
        die(f"{activity.relative_to(ROOT)} 에 FlutterActivity import가 없습니다:\n{source}")
    source = source.replace(
        "import io.flutter.embedding.android.FlutterActivity\n", imported, 1
    )
    body = """
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // muud 미디어 채널 (MethodChannel muud_edits/media + EventChannel muud_edits/export_progress)
        MuudMediaPlugin.registerWith(this, flutterEngine)
    }
}
"""
    if "class MainActivity : FlutterActivity()\n" not in source:
        die(f"{activity.relative_to(ROOT)} 에서 `class MainActivity : FlutterActivity()`를 찾지 못했습니다.")
    source = source.replace("class MainActivity : FlutterActivity()\n", body.lstrip("\n"), 1)
    write(activity, source)
    note(f"{activity.relative_to(ROOT)} 패치: MuudMediaPlugin 등록")


# ── Windows ─────────────────────────────────────────────────────────────────


def wire_windows() -> None:
    runner = APP / "windows" / "runner"
    if not runner.is_dir():
        die("app/windows 가 없습니다. 먼저 prepare_app.py 를 실행하세요.")

    copy_tree(
        NATIVE / "windows",
        runner / "muud",
        ["muud_media_plugin.h", "muud_media_plugin.cpp"],
    )

    # 플러그인은 별도 STATIC 라이브러리로 컴파일한다.
    # (러너 타깃은 /W4 /WX + _HAS_EXCEPTIONS=0 이라 nlohmann/json 과 맞지 않는다.)
    append_block(
        runner / "CMakeLists.txt",
        """
# ── muud 미디어 플러그인 (scripts/ci/wire_native.py 가 추가) ──────────────────
# 러너 타깃(apply_standard_settings)은 /W4 /WX, _HAS_EXCEPTIONS=0 이므로
# nlohmann/json 을 쓰는 플러그인은 경고·예외 설정이 다른 정적 라이브러리로 빌드한다.
add_library(muud_media_plugin STATIC
  "${CMAKE_CURRENT_SOURCE_DIR}/muud/muud_media_plugin.cpp"
)
target_compile_features(muud_media_plugin PRIVATE cxx_std_17)
target_include_directories(muud_media_plugin PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/muud"
)
target_compile_definitions(muud_media_plugin PRIVATE "NOMINMAX" "UNICODE" "_UNICODE")
target_compile_options(muud_media_plugin PRIVATE /EHsc /W3 /wd4100)
# flutter(INTERFACE)는 ephemeral 헤더만 주고, flutter/encodable_value.h 같은 C++ 래퍼
# 헤더는 flutter_wrapper_app 이 PUBLIC include 로 내보낸다(러너도 같은 타깃을 링크한다).
# PluginRegistrar/PluginRegistrarManager 구현은 flutter_wrapper_plugin 쪽에만 있다.
target_link_libraries(muud_media_plugin PRIVATE flutter_wrapper_app flutter_wrapper_plugin)
target_link_libraries(${BINARY_NAME} PRIVATE muud_media_plugin)

# muud_core.dll 은 워크플로우의 zip 단계에서 앱 번들 옆으로 복사한다.
# (여기 install()을 쓰면 INSTALL_BUNDLE_LIB_DIR 이 아직 정의되기 전이라 DESTINATION 이 비어 실패한다.)
""",
        token="muud_media_plugin",
    )

    window_cpp = runner / "flutter_window.cpp"
    insert_after(
        window_cpp,
        '#include "flutter/generated_plugin_registrant.h"\n',
        '#include "muud/muud_media_plugin.h"\n',
    )
    insert_after(
        window_cpp,
        "  RegisterPlugins(flutter_controller_->engine());\n",
        "  // muud 미디어 채널 등록 (scripts/ci/wire_native.py)\n"
        "  MuudMediaPlugin::RegisterWithRegistrar(flutter_controller_->engine());\n",
    )


# ── macOS / iOS (Swift) ─────────────────────────────────────────────────────


def merge_swift_into(target: pathlib.Path, host_imports: str) -> None:
    """Runner 타깃에 이미 포함된 Swift 파일 하나에 네이티브 소스를 합쳐 넣는다."""
    source = read(target)
    if MERGE_MARKER in source:
        note(f"{target.relative_to(ROOT)} 는 이미 병합되어 있습니다(건너뜀)")
        return
    pieces = []
    for name in APPLE_SWIFT:
        path = NATIVE / "apple" / name
        if not path.exists():
            die(f"네이티브 소스가 없습니다: {path.relative_to(ROOT)}")
        pieces.append(f"\n// ═══ app/native/apple/{name} ═══\n" + read(path).strip() + "\n")
    write(target, source.rstrip() + "\n" + MERGE_HEADER + "".join(pieces))
    note(f"{target.relative_to(ROOT)} 에 Swift {len(APPLE_SWIFT)}개 병합")


def add_plist_key(path: pathlib.Path, key: str, value: str) -> None:
    """Info.plist / entitlements 에 키를 추가한다(이미 있으면 건너뛴다)."""
    text = read(path)
    if f"<key>{key}</key>" in text:
        note(f"{path.relative_to(ROOT)} 에 {key} 이미 있음(건너뜀)")
        return
    idx = text.rfind("</dict>")
    if idx < 0:
        die(f"{path.relative_to(ROOT)} 에서 </dict> 를 찾지 못했습니다.")
    entry = f"\t<key>{key}</key>\n\t<string>{value}</string>\n" if isinstance(value, str) else ""
    write(path, text[:idx] + entry + text[idx:])
    note(f"{path.relative_to(ROOT)} 에 {key} 추가")


def add_plist_flag(path: pathlib.Path, key: str) -> None:
    text = read(path)
    if f"<key>{key}</key>" in text:
        note(f"{path.relative_to(ROOT)} 에 {key} 이미 있음(건너뜀)")
        return
    idx = text.rfind("</dict>")
    if idx < 0:
        die(f"{path.relative_to(ROOT)} 에서 </dict> 를 찾지 못했습니다.")
    write(path, text[:idx] + f"\t<key>{key}</key>\n\t<true/>\n" + text[idx:])
    note(f"{path.relative_to(ROOT)} 에 {key} 추가")


# ── Apple: Rust 코어 라이브러리 배선 ───────────────────────────────────────────
#
# Rust 코어(flutter_rust_bridge)는 다음 두 가지 방식으로 앱에 들어간다.
#   * macOS: universal dylib 을 `<App>.app/Contents/Frameworks/` 에 넣고 코드 서명한다.
#            Dart 는 실행 파일 기준 `../Frameworks/libmuud_core.dylib` 를 dlopen 한다.
#   * iOS:   정적 라이브러리(.a)를 Runner 실행 파일에 링크한다(-force_load).
#            Dart 는 `ExternalLibrary.process()` 로 프로세스 안의 심볼을 찾는다.
#
# 라이브러리 파일은 워크플로의 "Rust 코어" 단계가 `dist/native/` 에 만들어 두고,
# 이 스크립트는 Xcode 프로젝트가 그 파일을 **빌드 시점에** 가져가도록 배선만 한다.

MUUDPBX_PHASE_ID = "4D555544C0DE000000000001"  # pbxproj 객체 ID(파일 내 유일)
MUUDPBX_PHASE_NAME = "muud Rust 코어 복사"

MACOS_CORE_COPY_SCRIPT = f"""set -e
SRC="${{SRCROOT}}/../../dist/native/libmuud_core.dylib"
DST="${{BUILT_PRODUCTS_DIR}}/${{FRAMEWORKS_FOLDER_PATH}}"
if [ ! -f "$SRC" ]; then
  echo "muud: Rust 코어 dylib 이 없습니다: $SRC" >&2
  exit 1
fi
mkdir -p "$DST"
cp -f "$SRC" "$DST/libmuud_core.dylib"
# arm64 macOS 는 프로세스가 로드하는 모든 코드에 서명이 필요하다 → ad-hoc 서명.
codesign --force --sign - "$DST/libmuud_core.dylib"
echo "muud: libmuud_core.dylib → $DST"
"""


def _pbx_quote(text: str) -> str:
    """pbxproj 문자열 리터럴로 감싼다(Xcode 는 "..." 안에서 \n 과 \" 를 해석한다)."""
    escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def add_macos_core_copy_phase(pbxproj: pathlib.Path) -> None:
    text = read(pbxproj)
    if MUUDPBX_PHASE_ID in text or MUUDPBX_PHASE_NAME in text:
        note(f"{pbxproj.relative_to(ROOT)} 는 이미 Rust 코어 복사 단계가 있습니다(건너뜀)")
        return

    # 1) Runner 타깃의 buildPhases 목록 끝(마지막 ShellScript 뒤)에 단계를 추가한다.
    runner_anchor = (
        "\t\t\t\t33CC10EB2044A3C60003C045 /* Resources */,\n"
        "\t\t\t\t33CC110E2044A8840003C045 /* Bundle Framework */,\n"
        "\t\t\t\t3399D490228B24CF009A79C7 /* ShellScript */,\n"
    )
    if runner_anchor not in text:
        die(
            f"{pbxproj.relative_to(ROOT)} 에서 Runner 타깃의 buildPhases 앵커를 찾지 못했습니다.\n"
            "  상위 Flutter 템플릿의 macOS 프로젝트 구조가 바뀌었는지 확인하세요."
        )
    text = text.replace(
        runner_anchor,
        runner_anchor + f"\t\t\t\t{MUUDPBX_PHASE_ID} /* {MUUDPBX_PHASE_NAME} */,\n",
        1,
    )

    # 2) PBXShellScriptBuildPhase 섹션에 실제 단계를 정의한다.
    section_anchor = "/* End PBXShellScriptBuildPhase section */"
    if section_anchor not in text:
        die(f"{pbxproj.relative_to(ROOT)} 에 PBXShellScriptBuildPhase 섹션이 없습니다.")
    phase = (
        f"\t\t{MUUDPBX_PHASE_ID} /* {MUUDPBX_PHASE_NAME} */ = {{\n"
        "\t\t\tisa = PBXShellScriptBuildPhase;\n"
        "\t\t\talwaysOutOfDate = 1;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        "\t\t\t);\n"
        "\t\t\tinputFileListPaths = (\n"
        "\t\t\t);\n"
        "\t\t\tinputPaths = (\n"
        "\t\t\t);\n"
        f'\t\t\tname = "{MUUDPBX_PHASE_NAME}";\n'
        "\t\t\toutputFileListPaths = (\n"
        "\t\t\t);\n"
        "\t\t\toutputPaths = (\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t\tshellPath = /bin/sh;\n"
        f"\t\t\tshellScript = {_pbx_quote(MACOS_CORE_COPY_SCRIPT)};\n"
        "\t\t};\n"
    )
    text = text.replace(section_anchor, phase + section_anchor, 1)
    write(pbxproj, text)
    note(f"{pbxproj.relative_to(ROOT)} 패치: Rust 코어 dylib 복사 빌드 단계 추가")


def add_ios_core_link_flags(pbxproj: pathlib.Path) -> None:
    text = read(pbxproj)
    if "libmuud_core.a" in text:
        note(f"{pbxproj.relative_to(ROOT)} 는 이미 Rust 코어 링크 설정이 있습니다(건너뜀)")
        return

    anchor = "\t\t\t\tINFOPLIST_FILE = Runner/Info.plist;\n"
    count = text.count(anchor)
    if count != 3:
        die(
            f"{pbxproj.relative_to(ROOT)} 의 Runner 설정 블록에서 INFOPLIST_FILE 앵커를 "
            f"{count}번 찾았습니다(3개 Debug/Release/Profile 기대)."
        )
    flags = (
        "\t\t\t\tOTHER_LDFLAGS = (\n"
        '\t\t\t\t\t"$(inherited)",\n'
        '\t\t\t\t\t"-force_load",\n'
        '\t\t\t\t\t"$(SRCROOT)/../../dist/native/libmuud_core.a",\n'
        "\t\t\t\t);\n"
        # Dart 는 런타임에 심볼 이름으로 코어를 찾으므로(dlsym), Swift 쪽에서 참조하지 않는
        # Rust 심볼이 dead-strip 되면 안 된다. Release 기본값(YES)을 끈다.
        "\t\t\t\tDEAD_CODE_STRIPPING = NO;\n"
    )
    text = text.replace(anchor, anchor + flags)
    write(pbxproj, text)
    note(f"{pbxproj.relative_to(ROOT)} 패치: libmuud_core.a -force_load 링크")


def wire_macos() -> None:
    runner = APP / "macos" / "Runner"
    if not runner.is_dir():
        die("app/macos 가 없습니다. 먼저 prepare_app.py 를 실행하세요.")

    main_window = runner / "MainFlutterWindow.swift"
    merge_swift_into(main_window, "FlutterMacOS")
    insert_after(
        main_window,
        "RegisterGeneratedPlugins(registry: flutterViewController)\n",
        "\n    // muud 미디어 채널 등록 (scripts/ci/wire_native.py)\n"
        '    MuudMediaPlugin.register(with: flutterViewController.registrar(forPlugin: "MuudMediaPlugin"))\n',
    )

    # 샌드박스에서 사용자가 고른 미디어 파일을 읽고 쓸 수 있어야 한다.
    for name in ("DebugProfile.entitlements", "Release.entitlements"):
        path = runner / name
        if path.exists():
            add_plist_flag(path, "com.apple.security.files.user-selected.read-write")
            add_plist_flag(path, "com.apple.security.files.bookmarks.app-scope")

    add_plist_key(
        runner / "Info.plist",
        "NSPhotoLibraryUsageDescription",
        "편집할 사진·영상을 고르기 위해 사진 보관함에 접근합니다.",
    )

    # Rust 코어(dylib)를 앱 번들에 넣는다.
    add_macos_core_copy_phase(APP / "macos" / "Runner.xcodeproj" / "project.pbxproj")


def wire_ios() -> None:
    runner = APP / "ios" / "Runner"
    if not runner.is_dir():
        die("app/ios 가 없습니다. 먼저 prepare_app.py 를 실행하세요.")

    app_delegate = runner / "AppDelegate.swift"
    merge_swift_into(app_delegate, "Flutter")

    text = read(app_delegate)
    # Flutter 3.44+ 템플릿: FlutterImplicitEngineDelegate
    if "GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)" in text:
        registry = "engineBridge.pluginRegistry"
    elif "GeneratedPluginRegistrant.register(with: self)" in text:
        registry = "self"
    else:
        die(
            "AppDelegate.swift 에서 플러그인 등록 지점을 찾지 못했습니다.\n"
            f"  --- {app_delegate.relative_to(ROOT)} ---\n{text[:1500]}"
        )
    anchor = f"GeneratedPluginRegistrant.register(with: {registry})\n"
    # iOS 의 FlutterPluginRegistry.registrar(forPlugin:) 는 optional 을 돌려준다
    # (macOS 의 FlutterViewController 쪽은 non-optional 이라 그대로 넘긴다).
    insert_after(
        app_delegate,
        anchor,
        f'    // muud 미디어 채널 등록 (scripts/ci/wire_native.py)\n'
        f'    if let muudRegistrar = {registry}.registrar(forPlugin: "MuudMediaPlugin") {{\n'
        f'      MuudMediaPlugin.register(with: muudRegistrar)\n'
        f'    }}\n',
    )

    add_plist_key(
        runner / "Info.plist",
        "NSPhotoLibraryUsageDescription",
        "편집할 사진·영상을 고르기 위해 사진 보관함에 접근합니다.",
    )

    # Rust 코어(정적 라이브러리)를 Runner 실행 파일에 링크한다.
    add_ios_core_link_flags(APP / "ios" / "Runner.xcodeproj" / "project.pbxproj")


WIRERS = {
    "android": wire_android,
    "windows": wire_windows,
    "macos": wire_macos,
    "ios": wire_ios,
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=sorted(WIRERS))
    args = parser.parse_args()
    print(f"▶ {args.platform} 네이티브 연결")
    WIRERS[args.platform]()


if __name__ == "__main__":
    main()
