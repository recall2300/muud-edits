# flutter_rust_bridge 바인딩 (생성 파일)

이 디렉터리의 파일은 `flutter_rust_bridge_codegen generate`가 만든다. 직접 고치지 않는다.

| 파일 | 내용 |
|---|---|
| `bridge.dart` | `rust_core/src/bridge.rs`의 pub 함수 → Dart 함수 |
| `frb_generated.dart` | `RustLib` 엔트리포인트(코드젠/런타임 버전·콘텐츠 해시 검사 포함) |
| `frb_generated.io.dart` / `.web.dart` | 플랫폼별 로딩·코덱 |

다시 생성:

```bash
cd app
flutter_rust_bridge_codegen generate    # 버전 2.13.0 (pubspec/Cargo.toml 과 동일)
```

로딩은 `lib/rust_core_loader.dart`가 플랫폼별 경로를 골라 `RustLib.init()`을 호출한다.
