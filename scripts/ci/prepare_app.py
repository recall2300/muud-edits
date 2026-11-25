#!/usr/bin/env python3
"""CI에서 플랫폼 폴더(`android/`, `windows/`, `macos/`, `ios/`)를 만든다.

    python3 scripts/ci/prepare_app.py android,windows,macos,ios

`app/`에는 `lib/`, `pubspec.yaml`, `analysis_options.yaml`, `app/native/`만 커밋되어
있고 플랫폼 폴더는 커밋하지 않는다. CI가 매번 `flutter create`로 만들고
`scripts/ci/wire_native.py`가 네이티브 미디어 엔진을 붙인다.

`flutter create`는 이미 있는 파일(pubspec.yaml, lib/main.dart)은 덮어쓰지 않지만,
없는 파일은 새로 만든다. 그중 위젯 테스트와 README는 이 프로젝트 내용과 맞지 않으므로
(템플릿의 `MyApp`을 참조해 `flutter analyze`가 깨진다) 지운다.
"""

from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "app"

ORG = "com.muud.edits"
PROJECT_NAME = "muud_edits"

# Windows 에서는 flutter 가 `flutter.bat` 이라 subprocess 가 그냥은 찾지 못한다.
# shutil.which 는 PATHEXT 를 적용하므로 .bat 까지 찾아준다.
FLUTTER = shutil.which("flutter") or shutil.which("flutter.bat") or "flutter"


def run(cmd: list[str], cwd: pathlib.Path) -> None:
    print("$ " + " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=str(cwd), check=True)


def drop_template_leftovers() -> None:
    widget_test = APP / "test" / "widget_test.dart"
    if widget_test.exists() and "MyApp" in widget_test.read_text(encoding="utf-8"):
        widget_test.unlink()
        print(f"  • 템플릿 위젯 테스트 삭제: {widget_test.relative_to(ROOT)}")

    readme = APP / "README.md"
    if readme.exists() and "A new Flutter project" in readme.read_text(encoding="utf-8"):
        readme.unlink()
        print(f"  • 템플릿 README 삭제: {readme.relative_to(ROOT)}")

    # .gitignore/.iml 은 루트 .gitignore가 이미 처리하므로 템플릿이 만든 중복만 지운다.
    for leftover in ("muud_edits.iml", ".gitignore"):
        path = APP / leftover
        if path.is_file():
            path.unlink()
            print(f"  • 템플릿 파일 정리: {path.relative_to(ROOT)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "platforms",
        help="쉼표로 구분한 플랫폼 목록 (android,windows,macos,ios)",
    )
    args = parser.parse_args()

    platforms = [p.strip() for p in args.platforms.split(",") if p.strip()]
    if not platforms:
        print("플랫폼을 지정하세요", file=sys.stderr)
        sys.exit(2)

    run(
        [
            FLUTTER,
            "create",
            f"--platforms={','.join(platforms)}",
            f"--org={ORG}",
            f"--project-name={PROJECT_NAME}",
            ".",
        ],
        cwd=APP,
    )
    drop_template_leftovers()

    for platform in platforms:
        folder = APP / platform
        state = "있음" if folder.is_dir() else "없음"
        print(f"  • app/{platform}: {state}")


if __name__ == "__main__":
    main()
