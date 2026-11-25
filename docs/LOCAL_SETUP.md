# 로컬 개발 환경 구축

이 문서는 **사용자 PC**에서 muud-edits를 빌드/실행하는 순서다.
(샌드박스/CI에는 Rust와 Flutter가 없을 수 있다. 그 경우에도 `rust_core`는 독립적으로 테스트된다.)

---

## 0. 공통 준비물

| 도구 | 버전 | 확인 |
|---|---|---|
| Rust | stable 1.77+ | `rustc --version`, `cargo --version` |
| Flutter | 3.27+ (Dart 3.6+) | `flutter --version` |
| Git | — | `git --version` |
| FFmpeg | 6+ (Windows 내보내기) | `ffmpeg -version`, `ffprobe -version` |

```bash
# Rust (없으면)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
# Flutter (macOS/Linux)
brew install --cask flutter      # 또는 공식 SDK 압축 해제 후 PATH 추가
```

Rust 코어만 먼저 확인:

```bash
cd rust_core
cargo test                       # 141개 (모델/커맨드/그래프/진행률/프로브/브리지)
cargo run --example demo_project
```

---

## 1. Flutter 앱 초기화

`app/`에는 `lib/`, `pubspec.yaml`, `flutter_rust_bridge.yaml`, `native/`가 들어 있다.
플랫폼 폴더(`android/`, `ios/`, `macos/`, `windows/`)는 다음 명령으로 만든다.

```bash
cd app

# 필요한 플랫폼만 생성 (기존 lib/는 덮어쓰지 않는다)
flutter create --platforms=macos,windows,android,ios \
  --org com.muud.edits --project-name muud_edits .

flutter pub get
```

> `flutter create`가 `lib/main.dart`를 덮어쓸 수 있다. 그럴 때는 git으로 되돌리면 된다
> (`git checkout -- lib/main.dart`).

---

## 2. Rust 브리지 생성

```bash
cd app
dart pub global activate flutter_rust_bridge_codegen   # 최초 1회
dart run flutter_rust_bridge_codegen generate
```

생성되는 것:

| 경로 | 내용 |
|---|---|
| `lib/src/rust/api.dart` | `rust_core/src/bridge.rs`의 pub 함수 → Dart 함수 (스텁을 덮어쓴다) |
| `lib/src/rust/frb_generated.dart` | `RustLib.init()` 등 로더 |
| `lib/src/rust/frb_generated.io.dart` | 플랫폼별 라이브러리 로딩 |
| `rust_builder/` | 코어를 빌드해 앱에 넣는 Flutter 패키지(FRB 2.x 표준) |

생성 후 `lib/main.dart`의 주석을 따라 두 줄을 살린다.

```dart
import 'src/rust/frb_generated.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();      // 네이티브 코어 로드
  runApp(const MuudEditsApp());
}
```

> 생성된 Dart 함수의 인자 이름/타입이 `lib/core_bridge.dart`의 호출과 다르면
> **그 파일의 메서드 본문만** 고치면 된다(화면 코드는 영향 없음).
> `renderGraph`, `probeMediaInfo`, `exportJobCreate`, `exportJobEvent`, `exportJobCancel`도
> 같은 방식으로 `bridge.rs`에서 자동 생성된다.

---

## 3. 네이티브 미디어 레이어 연결

`app/native/README.md`에 채널 계약과 플랫폼별 한계가 정리되어 있다.
네이티브 파일을 붙이지 않아도 앱은 실행되며, 미디어 추가는 **수동 입력**으로,
내보내기는 "엔진 미연결" 안내로 폴백한다.

채널 이름은 4플랫폼 공통이다.

| 채널 | 종류 | 이름 |
|---|---|---|
| 메서드 | MethodChannel | `muud_edits/media` |
| 이벤트 | EventChannel | `muud_edits/export_progress` |

### 3.1 macOS

1. Xcode에서 `macos/Runner.xcworkspace`를 연다.
2. `app/native/apple/`의 Swift 파일 4개를 **Runner 타깃**에 추가한다
   (Add Files to "Runner" → Copy items if needed 해제, `Runner` 타깃 체크).
   * `MuudMediaPlugin.swift`
   * `MuudGraphModels.swift`
   * `AVMediaProbe.swift`
   * `AVExportEngine.swift`
3. `macos/Runner/MainFlutterWindow.swift`에서 플러그인을 등록한다.

```swift
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    RegisterGeneratedPlugins(registry: flutterViewController)

    // muud 미디어 채널
    MuudMediaPlugin.register(
      with: flutterViewController.registrar(forPlugin: "MuudMediaPlugin")
    )

    super.awakeFromNib()
  }
}
```

4. `macos/Runner/DebugProfile.entitlements`와 `Release.entitlements`에 파일 접근 권한:

```xml
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
```

(security-scoped bookmark 없이는 재시작 후 프로젝트가 미디어를 못 찾는다.)

### 3.2 iOS

1. `app/native/apple/`의 같은 Swift 파일 4개를 **Runner 타깃**에 추가한다.
2. `ios/Runner/AppDelegate.swift`에 등록:

```swift
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "MuudMediaPlugin") {
      MuudMediaPlugin.register(with: registrar)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
```

3. 파일 선택은 `file_picker`의 document picker를 쓰므로 사진 보관함 권한은 필요 없다.
   사진 앱에서 직접 가져오게 하려면 `NSPhotoLibraryUsageDescription`을 추가한다.
4. 백그라운드에서 긴 내보내기를 하려면 `BGProcessingTask` 등록이 별도로 필요하다(후속).

### 3.3 Android

1. `android/app/build.gradle(.kts)`에 Media3 의존성과 minSdk를 추가한다.

```kotlin
android {
    defaultConfig {
        minSdk = 26
    }
}

dependencies {
    implementation("androidx.media3:media3-transformer:1.5.1")
    implementation("androidx.media3:media3-effect:1.5.1")
    implementation("androidx.media3:media3-common:1.5.1")
}
```

2. `app/native/android/`의 Kotlin 파일 3개를
   `android/app/src/main/kotlin/com/muud/edits/media/`에 복사한다.
   * `MuudMediaPlugin.kt`
   * `MediaProbe.kt`
   * `ExportEngine.kt`

3. `MainActivity.kt`에서 등록:

```kotlin
import com.muud.edits.media.MuudMediaPlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MuudMediaPlugin.registerWith(flutterEngine)
    }
}
```

4. Android 13+에서 문서 선택기로 고른 파일은 SAF URI가 아니라 **경로**가 필요하다.
   `file_picker`가 캐시로 복사한 경로(`/data/user/0/…/cache/…`)를 그대로 넘기면 된다.
5. 기기별 MediaCodec 지원이 다르므로 첫 실행 시 `platformInfo`의
   `hardware_video_encoders` 값을 로그로 남긴다.

### 3.4 Windows

1. `app/native/windows/`의 `muud_media_plugin.h/.cpp`를
   `windows/runner/` 아래(예: `windows/runner/muud/`)에 복사한다.
2. `app/native/windows/CMakeLists.snippet.txt`의 내용을 참고해
   `windows/runner/CMakeLists.txt`에 소스와 include, nlohmann/json을 추가한다.
3. `windows/runner/flutter_window.cpp`에서 등록한다. `generated_plugin_registrant`와
   같은 `PluginRegistry` 패턴을 쓴다.

```cpp
#include "../../native/windows/muud_media_plugin.h"   // 복사한 경로에 맞춘다

// FlutterWindow::OnCreate() 안, RegisterPlugins(flutter_controller_->engine()); 다음 줄:
MuudMediaPlugin::RegisterWithRegistrar(flutter_controller_->engine());
```

`FlutterEngine`은 `PluginRegistry`를 구현하므로 생성된 `RegisterPlugins`와 동일한 방식으로
등록된다. 나중에 앱 소스를 바꾸지 않고 `generated_plugin_registrant.cc`에 넣고 싶으면
`registry->GetRegistrarForPlugin("MuudMedia")` 결과를 넘기는 오버로드
(`RegisterWithRegistrar(FlutterDesktopPluginRegistrarRef)`)를 쓰면 된다.

4. `ffmpeg.exe`와 `ffprobe.exe`를 빌드 출력 폴더(앱 실행 파일 옆)에 둔다.
   없으면 PATH에서 찾는다. HEVC는 Windows "HEVC 비디오 확장" 설치가 필요할 수 있다.

---

## 4. 플랫폼별 빌드

### macOS

```bash
xcode-select --install
rustup target add aarch64-apple-darwin x86_64-apple-darwin
flutter run -d macos
```

### Windows

```powershell
# Visual Studio 2022 → "Desktop development with C++" 워크로드 필요
rustup target add x86_64-pc-windows-msvc
flutter run -d windows
```

* Media Foundation 인코더는 설치된 MFT에 의존한다. HEVC 익스포트는
  Microsoft Store의 "HEVC 비디오 확장"이 필요할 수 있다.
* FFmpeg 폴백을 쓰려면 `ffmpeg.exe`/`ffprobe.exe`를 앱과 함께 배포하고 PATH를 잡아 준다.

### Android

```bash
# JDK 17, Android SDK(API 34), NDK r27
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk
cd app
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o android/app/src/main/jniLibs \
  build --manifest-path ../rust_core/Cargo.toml --release
flutter run -d <device>
```

* `android/app/build.gradle`에 `ndkVersion`과 `abiFilters`를 명시한다.
* 기기별 MediaCodec 지원이 다르므로, 첫 실행 시 `MediaCodecList` 프로브 결과를 로그로 남긴다.

### iOS

```bash
# Xcode 16+, CocoaPods
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cd app/ios && pod install
cd .. && flutter run -d <iPhone>
```

* `rust_core`는 iOS에서 `staticlib`로 링크된다(`Cargo.toml`의 `crate-type`에 포함).
* 시뮬레이터(arm64)와 기기(arm64)는 같은 아키텍처지만 SDK가 달라 각각 빌드해야 한다.

---

## 5. 자주 막히는 곳

| 증상 | 원인 / 해결 |
|---|---|
| `UnimplementedError: flutter_rust_bridge_codegen generate …` | 코드 생성 전이다. 2절 실행. |
| `Invalid argument(s): Failed to load dynamic library` | `RustLib.init()` 누락, 또는 플랫폼 폴더 재생성 후 `rust_builder` 경로가 깨짐 → `flutter clean && flutter pub get`. |
| `cargo: command not found` (빌드 중) | Flutter가 앱 빌드 시 cargo를 찾는다. 셸 PATH에 `~/.cargo/bin` 추가 후 IDE 재시작. |
| Android: `libmuud_core.so not found` | `cargo ndk` 산출물 경로(`jniLibs`)와 `abiFilters` 불일치. |
| macOS: 샌드박스에서 미디어 접근 실패 | entitlements + security-scoped bookmark(3.1절). |
| 프로젝트 JSON을 못 읽음 | 스키마 버전이 코드보다 높다(`unsupported_schema`). 앱을 최신으로. |
| "네이티브 미디어 엔진이 연결되지 않았습니다" | 3절의 플랫폼별 등록 누락. `platformInfo`가 빈 맵이면 채널 이름/등록을 확인. |
| iOS/macOS: `AVAssetExportSession`이 즉시 실패 | 출력 경로 권한, 컨테이너(mp4/mov), 이미지 클립 포함 여부 확인(이미지는 v1 미지원). |
| Windows: `ffmpeg를 시작하지 못했습니다` | `ffmpeg.exe`가 앱 옆에 없거나 PATH에 없음. `probe`도 같이 실패하면 `ffprobe.exe` 확인. |
| Android: `ExportException: 2002` | Media3가 기기 인코더를 못 찾음. H.264/1080p로 낮춰 재시도. |

---

## 6. 테스트

```bash
cd rust_core && cargo test              # 코어 141개
cd app && flutter test                  # 위젯 테스트(추가 예정)
cd app && flutter analyze               # 정적 분석
```

CI(권장 구성):

```yaml
# .github/workflows/core.yml (예시)
- rustup toolchain install stable
- cargo fmt --check && cargo clippy -- -D warnings
- cargo test --manifest-path rust_core/Cargo.toml
```
