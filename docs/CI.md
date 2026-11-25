# CI · 릴리즈 파이프라인

[`.github/workflows/ci-release.yml`](../.github/workflows/ci-release.yml) 하나로
**Rust 코어 검증 → 4플랫폼 빌드 → 태그 릴리즈**를 처리한다.

```text
push(main) / PR / 수동                tag push(v*)
        │                                   │
        ├─ rust-core     (fmt·clippy·test)  │
        ├─ flutter-analyze                  │
        ├─ build-android ─┐                 │
        ├─ build-windows ─┤ 아티팩트 ───────┴─► release (GitHub Release)
        ├─ build-macos   ─┤
        └─ build-ios     ─┘
```

## 잡 구성

| 잡 | 러너 | 하는 일 | 산출물 |
|---|---|---|---|
| `rust-core` | ubuntu-latest | `cargo fmt --check` · `cargo clippy`(경고만) · `cargo test` · `demo_project` 예제 실행 | — |
| `flutter-analyze` | ubuntu-latest | `flutter pub get` → `flutter analyze --no-fatal-infos` | — |
| `build-android` | ubuntu-latest | Rust 코어 → `jniLibs`(arm64-v8a·armeabi-v7a·x86_64), `flutter build apk --release` | `muud-edits-android.apk` |
| `build-windows` | windows-latest | nlohmann/json 준비, `muud_core.dll`, `flutter build windows --release` | `muud-edits-windows-x64.zip` |
| `build-macos` | macos-latest | `libmuud_core.dylib`(arm64+x86_64 universal), `flutter build macos --release` | `muud-edits-macos-<arch>.zip`, `muud-core-macos-dylib` |
| `build-ios` | macos-latest | `libmuud_core.a`, `flutter build ios --release --no-codesign` | `muud-edits-ios-unsigned.zip`, `muud-core-ios-staticlib` |
| `release` | ubuntu-latest | `v*` 태그에서만. 모든 빌드 성공 시 아티팩트 + `SHA256SUMS.txt` 업로드 | GitHub Release |

## 플랫폼 폴더는 커밋하지 않는다

`app/`에는 `lib/`, `pubspec.yaml`, `analysis_options.yaml`, `native/`만 있다.
`android/`, `ios/`, `macos/`, `windows/` 폴더는 **CI가 매번 `flutter create`로 만들고**,
네이티브 미디어 엔진을 스크립트로 붙인다. 생성물을 커밋하지 않으므로
Flutter 버전을 올려도 플랫폼 폴더를 손으로 다시 만들 필요가 없다.

### 1) 플랫폼 폴더 생성 — `scripts/ci/prepare_app.py`

```bash
python3 scripts/ci/prepare_app.py android,windows,macos,ios
```

`flutter create --platforms=... --org com.muud.edits --project-name muud_edits .` 를 실행하고,
템플릿이 만드는 `test/widget_test.dart`(템플릿 `MyApp` 참조 → 분석 실패)와
`README.md`, `.iml`, `.gitignore`를 정리한다.

### 2) 네이티브 연결 — `scripts/ci/wire_native.py`

```bash
python3 scripts/ci/wire_native.py android   # build.gradle.kts(minSdk 26, Media3) + Kotlin 소스 + MainActivity 등록
python3 scripts/ci/wire_native.py windows   # CMake 정적 라이브러리 + flutter_window.cpp 등록
python3 scripts/ci/wire_native.py macos     # Swift 병합 + MainFlutterWindow 등록 + entitlements
python3 scripts/ci/wire_native.py ios       # Swift 병합 + AppDelegate 등록
```

* 앵커 문자열을 찾지 못하면 **파일 내용과 함께 실패**한다. Flutter 템플릿이 바뀌면
  조용히 지나가지 않고 CI에서 바로 드러난다.
* 여러 번 실행해도 안전하다(이미 적용된 단계는 건너뛴다).
* Apple(macOS/iOS)은 Xcode 프로젝트(`project.pbxproj`)를 수정하지 않는다. Runner 타깃에
  이미 포함된 `MainFlutterWindow.swift` / `AppDelegate.swift` 파일 끝에
  `app/native/apple/*.swift`를 합쳐 컴파일한다(CocoaPods·Ruby 의존 없음).
  로컬 개발에서는 `docs/LOCAL_SETUP.md` 3.1·3.2절처럼 Xcode에서 직접 파일을 추가하는 편이 낫다.
* Windows 플러그인은 러너 타깃(`/W4 /WX`, `_HAS_EXCEPTIONS=0`)과 분리해
  **정적 라이브러리**(`/W3 /EHsc`)로 빌드한다. nlohmann/json 이 그 설정과 맞지 않기 때문이다.

### 3) Rust 코어 크로스 컴파일

`flutter_rust_bridge` 코드 생성은 아직 CI에 넣지 않았다(아래 "알려진 한계").
대신 **플랫폼별 네이티브 라이브러리를 실제로 빌드**해 링크 가능성을 검증한다.

| 플랫폼 | 타깃 | 링커/비고 |
|---|---|---|
| Android | `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android` | NDK clang `*-android26-clang` (`minSdk 26` 과 일치) |
| Windows | `x86_64-pc-windows-msvc` | 기본 MSVC 툴체인, `muud_core.dll` |
| macOS | `aarch64-apple-darwin`, `x86_64-apple-darwin` | `lipo` 로 universal dylib |
| iOS | `aarch64-apple-ios` | `staticlib`(`muud_core.a`) |

## 릴리스 방법

```bash
git tag v0.1.0
git push origin v0.1.0
```

태그가 올라가면 6개 잡이 모두 성공한 경우에만 Release가 만들어지고,
APK · Windows zip · macOS zip · iOS unsigned zip · `SHA256SUMS.txt`가 첨부된다.
버전 표기는 `app/pubspec.yaml`의 `version:`과 맞춘다.

## 알려진 한계 (CI 기준)

* **flutter_rust_bridge 코드 생성 미연결**: `rust_core`에 `flutter_rust_bridge` 크레이트 의존성과
  생성된 `frb_generated.rs`가 아직 없다. 지금 앱은 `lib/src/rust/api.dart` 스텁을 쓰므로
  Rust 코어 호출이 `UnimplementedError`로 끝나고 화면에 "브리지 미생성" 안내가 뜬다.
  다음 단계: `rust_core/Cargo.toml`에 `flutter_rust_bridge = "=2.13.0"` 추가 →
  `dart run flutter_rust_bridge_codegen generate` → 생성물 커밋 →
  `rust_builder` 가 만드는 `build.dart` 훅이 각 플랫폼 빌드에서 코어를 자동 빌드·링크한다.
* **서명 없음**: Android는 템플릿의 debug 서명, iOS는 `--no-codesign`, macOS는 ad-hoc 서명이다.
  배포하려면 keystore·인증서·notarization 을 시크릿으로 넣어야 한다.
* **FFmpeg 미포함**: Windows 내보내기는 `ffmpeg.exe`/`ffprobe.exe`가 앱 옆에 있어야 한다.
  CI는 바이너리를 넣지 않는다(라이선스 검토 후 별도 단계로).
* **macOS/iOS 아키텍처**: macOS 아티팩트 이름은 러너 아키텍처(`macos-latest` = arm64)를 따른다.
  Intel 전용 zip 이 필요하면 `runs-on: macos-13` 잡을 추가한다.
* **clippy 는 실패시키지 않는다**: 경고는 로그로만 남는다. 기준을 올릴 때는
  `cargo clippy --all-targets --locked -- -D warnings` 로 바꾸면 된다.

## 실패했을 때 볼 곳

```bash
gh run list -R recall2300/muud-edits --limit 5
gh run view <run-id> -R recall2300/muud-edits --log-failed
```

| 증상 | 원인 |
|---|---|
| `예상한 앵커를 찾지 못했습니다` | `flutter create` 템플릿이 바뀜 → `scripts/ci/wire_native.py` 의 앵커 수정 |
| Android `minSdk` / Media3 오류 | `wire_native.py android` 의 `MEDIA3_VERSION` 조정 |
| Windows `C2220`/`C2039` | 플러그인 C++ 컴파일 오류 → `/W3` 유지, 필요한 `#include` 추가 |
| iOS/macOS `cannot find 'MuudMediaPlugin'` | Swift 병합이 안 됨 → `wire_native.py` 로그 확인 |
| `flutter analyze` 가 info로 실패 | `--no-fatal-infos` 유지 여부 확인(`material_ui` 이전 전까지) |
