# muud-edits

[![CI · Release](https://github.com/recall2300/muud-edits/actions/workflows/ci-release.yml/badge.svg)](https://github.com/recall2300/muud-edits/actions/workflows/ci-release.yml)

**워터마크 없는 숏폼 영상 편집기.** Flutter(UI) + Rust(코어 엔진) + OS 하드웨어 가속.
Windows · macOS · Android · iOS.

> 이 저장소는 **1단계(MVP) 코어가 동작하고, 4플랫폼 네이티브 미디어 레이어의
> 1차 구현이 들어간 상태**다. 타임라인·편집 커맨드(undo/redo)·저장·자막·
> 내보내기 계획·**결정적 렌더 그래프**·진행률/취소 상태·미디어 프로브까지는
> Rust 테스트로 검증되고, 실제 디코드/합성/인코딩은
> `app/native/`의 AVFoundation·Media3·FFmpeg 파이프라인이 맡는다.
> 실기기/Xcode/Android Studio/MSVC 빌드 검증은 아직 남아 있다
> (`ARCHITECTURE.md` 16절 체크리스트).

---

## 미리보기·내보내기 현재 상태 (v0.1.7)

| 기능 | 상태 |
|---|---|
| 미리보기 재생(영상 프레임 + 소리) | ✅ `video_player`(Android ExoPlayer · iOS/macOS AVFoundation) + `video_player_win`(Windows Media Foundation) |
| Android 렌더링 경로 | ⚠️ **Skia(GLES)** — Impeller 외부 텍스처 경로에서 큰 영상을 이어 재생할 때 끊기는 보고가 있어 opt-out (되돌리기: `EnableImpeller` meta-data 한 줄 삭제) |
| 재생/일시정지 · 타임라인 스크럽 · 프레임 이동 | ✅ **재생 중에는 플레이어 위치가 재생 헤드의 시계**(벽시계는 빈 구간·이미지에서만) |
| 클립 매핑(트림·분할·배속·빈 구간·다중 클립) | ✅ 순수 함수 `resolvePreviewSelection` + 단위 테스트 |
| 이어 재생 끊김 | ✅ 재생 중 틱은 플레이헤드만 옮긴다(플랫폼 호출 0회) · 같은 클립 재생 중 시크 없음 · 다음 클립은 경계 전에 미리 연다 |
| 텍스트/자막 오버레이 | ✅ 재생 헤드 시각 범위에 맞춰 미리보기 위에 표시 |
| 별도 오디오 트랙 · 클립 볼륨/음소거 | ✅ (플레이어 볼륨 0~100%) |
| 프로젝트 저장/열기(`.muudproj`) | ✅ 저장 시 Downloads(Android 10+)로도 복사, 공유 가능 |
| Android 내보내기 | ✅ Media3 Transformer — 영상 컷/병합 + 원본 음성, 완료 후 MediaStore(갤러리/다운로드)로 공개 + 공유/열기 |
| 빈 구간(클립 사이 공백) | ✅ 안드로이드 `addGap`, Windows `color`+`adelay` — 검은 화면·무음으로 채워 영상/자막/오디오 싱크 유지 (v0.1.6) |
| 배속 | ✅ Windows 는 `setpts` 1회만(이전 2중 적용 버그 수정), Android 는 SpeedChange+Sonic (v0.1.6) |
| 자막·텍스트 영상에 새기기(burn-in) | ✅ iOS/macOS(AVFoundation 레이어) · Windows(SRT+subtitles 필터) · Android(OverlayEffect) |
| 사진 클립 내보내기 | ✅ Android(`setImageDurationMs`) · iOS/macOS — ⚠️ Windows 는 아직 영상만 합성(시트에 명시) |
| 오디오 볼륨(gain) | ✅ Android 는 muted 뿐 아니라 실제 gain 반영(v0.1.6). 미리보기는 플랫폼 한계로 0~1.0 |
| Windows/macOS/iOS 내보내기 | ⚠️ 네이티브 구현은 있고 CI 빌드는 통과하지만, 실기기 검증은 아직 |
| 타임라인 줌/스크롤 · 드래그 편집 | ✅ 핀치 줌(0.25~24x)·가로/세로 스크롤, 클립 본체 드래그=이동, 좌우 핸들=트림 (v0.1.6) |
| 트랙 음소거/숨김/잠금 | ✅ 타임라인 왼쪽 거터 토글 |
| UI/UX | ✅ **Astryx 토큰 이식** — 시맨틱 간격/텍스트/표면, 반응형 작업 공간(≥1024 사이드 패널 · 768~1023 축소 패널 · <768 하단 시트), 인스펙터 폭·타임라인 높이 리사이즈 핸들, 48dp 터치 타깃 (v0.1.7) |

> 미리보기는 "지금 재생 헤드에 해당하는 클립 하나"를 플레이어에 물려 재생한다.
> **재생 중에는 플레이어가 시계**이고(플레이어가 알려 주는 위치를 100ms 사이만 벽시계로
> 이어 붙인다), 클립이 바뀔 때만 시크한다. 재생 중 화면 전체를 다시 그리지 않도록
> 재생 헤드는 별도 노티파이어로 타임코드·플레이헤드 선만 갱신한다.
> v0.1.5부터 재생 중 틱은 **플레이헤드만 옮기고 플랫폼(플레이어)은 건드리지 않는다** —
> 열기·시크·재생은 클립 전환·편집·재생 시작 같은 사건에만 일어난다.
> 클립 경계는 다음 클립을 미리 열어 두어 전환 지연을 줄였고, 서로 다른 파일을 오갈 때는
> 여전히 짧은 전환 시간이 있다(합성 파이프라인은 2단계 과제).

---

## UI/UX — Astryx 이식 (v0.1.7)

외부 디자인 패키지를 넣지 않고, 메타 Astryx 의 **시맨틱 토큰**과
**outside-in 레이아웃**을 Flutter 기본 위젯 위에 직접 구현했다.

* **토큰 2계층** — `app/lib/theme.dart`: 원시 팔레트 위에
  `EditorSpacing`(4px 스케일, content line 16) · `EditorRadius` · `EditorStroke`(1px) ·
  `EditorText`(display/lead/section/body/label/caption, 1·2·3차 색) ·
  `EditorSurfaces`(canvas→panel→raised→overlay) · `EditorDensity`(touch 48dp / compact 32dp) ·
  `EditorBreakpoints`(768 / 1024). 위젯은 색을 직접 만들지 않고 토큰만 읽는다.
* **레이아웃** — `app/lib/editor/workspace.dart`:
  * `≥1024px`: 상단 바 + [미리보기 │ 리사이즈 가능 인스펙터] + 트랜스포트 + 타임라인
  * `768~1023px`: 2영역. 클립을 선택했을 때만 축소 폭 패널이 붙는다
  * `<768px`: 인스펙터를 하단 BottomSheet 로 스왑(타임라인은 시트 위에 남는다), 툴바 48dp
* **컨테이너** — `EditorSection` + 1px `Divider` + 단일 패딩 라인. 카드 안의 카드 없음.
  영역마다 lead 하나와 primary action 하나(상단 바의 "내보내기")만 강조한다.
* **회귀 테스트** — `app/test/theme_tokens_test.dart`, `editor_layout_test.dart`,
  `inspector_panel_test.dart` (총 72개 위젯/단위 테스트).

## 지금 바로 확인할 수 있는 것

Rust 코어는 미디어 파일 없이도 완전히 돌아간다.

```bash
cd rust_core
cargo test                 # 141개 테스트 (모델/커맨드/undo/저장/그래프/진행률/프로브/브리지)
cargo run --example demo_project
```

`demo_project`는 다음을 실제로 수행한다.

1. 1080x1920 / 30fps 프로젝트 생성
2. 클립 2개 배치 → 0.8x 슬로모션 → 헤드 트림 → 분할 → 뒷부분 삭제
3. 텍스트 오버레이 + 자동 자막(Whisper 흉내) + 자막 수정
4. 되돌리기/다시 적용
5. **플랫폼별 내보내기 계획**(macOS/Windows/Android/iOS/Linux)과 ffmpeg 인자 출력
6. `.muudproj` 저장 → 다시 불러와 동일성 검증 → SRT 저장 → 불변식 검증

`RenderGraph`·`ExportProgress`·`MediaProbeInfo`는 `bridge.rs`의
`render_graph` / `export_job_event` / `probe_media_info`로 노출된다
([`docs/BRIDGE_CONTRACT.md`](docs/BRIDGE_CONTRACT.md) 6절).

출력 예:

```text
▶ 플랫폼별 내보내기 계획
  - macos: mp4 1080x1920@30 · h264 (h264_videotoolbox) · 8087kbps · 워터마크 없음
  - android: mp4 1080x1920@30 · h264 (h264_mediacodec) · 8087kbps · 워터마크 없음
▶ 불변식 검증: 통과
```

## Flutter 앱 (UI 스캐폴딩)

`app/`에는 편집 화면이 들어 있다: 반응형 작업 공간(사이드 패널/하단 시트),
프리뷰 패널, 타임라인(CustomPainter), 트랜스포트 바, 클립 인스펙터,
내보내기 시트(진행률/취소 포함).
파일 선택 → 네이티브 프로브 → 클립 추가 흐름과, 렌더 그래프를 네이티브 엔진에
넘기는 내보내기 흐름이 연결되어 있다.

```bash
cd app
flutter pub get
dart run flutter_rust_bridge_codegen generate   # Rust 바인딩 생성
flutter run -d macos                            # 또는 windows / android / ios
```

> `lib/src/rust/`의 바인딩은 **커밋되어 있다**(생성 결과 포함). 코드를 바꿨을 때만
> 다시 생성하면 된다. 자세한 순서는 [`docs/LOCAL_SETUP.md`](docs/LOCAL_SETUP.md).
>
> 앱은 시작할 때 플랫폼별 Rust 라이브러리를 직접 찾아 로드한다
> (`lib/rust_core_loader.dart`): Android `libmuud_core.so`(jniLibs), Windows `muud_core.dll`,
> macOS `<App>.app/Contents/Frameworks/libmuud_core.dylib`, iOS 정적 링크.

## CI · 릴리스

GitHub Actions가 `main` push/PR마다 **Rust 코어 검증 + 4플랫폼 빌드**를 돌리고,
`v*` 태그를 밀면 빌드 산출물을 모아 **GitHub Release**를 만든다.

| 잡 | 러너 | 산출물 |
|---|---|---|
| `rust-core` | ubuntu | `cargo fmt --check` · `clippy` · `cargo test` |
| `flutter-analyze` | ubuntu | `flutter analyze` |
| `build-android` | ubuntu | `muud-edits-android.apk` |
| `build-windows` | windows | `muud-edits-windows-x64.zip` |
| `build-macos` | macOS | `muud-edits-macos-<arch>.zip` |
| `build-ios` | macOS | `muud-edits-ios-unsigned.zip` (컴파일 검증) |

플랫폼 폴더(`android/`, `ios/`, `macos/`, `windows/`)는 저장소에 커밋하지 않는다.
CI가 `flutter create`로 만들고 [`scripts/ci/wire_native.py`](scripts/ci/wire_native.py)가
`app/native/`의 미디어 엔진을 붙인다. 구조와 한계는 [`docs/CI.md`](docs/CI.md).

```bash
# 릴리스 (모든 빌드가 통과하면 Release가 만들어진다)
git tag v0.1.0 && git push origin v0.1.0
```

## 구조

```text
muud-edits/
├── ARCHITECTURE.md            구조·불변식·플랫폼 전략·MVP/2단계 로드맵
├── .github/workflows/         CI + 릴리스 (docs/CI.md)
├── scripts/ci/                플랫폼 폴더 생성 · 네이티브 연결 스크립트
├── docs/
│   ├── LOCAL_SETUP.md         플랫폼별 개발 환경 + 실행 순서
│   ├── CI.md                  CI · 릴리스 파이프라인
│   └── BRIDGE_CONTRACT.md     Dart ↔ Rust JSON 계약(커맨드/응답/에러 코드)
├── rust_core/                 ✅ 동작하는 코어 엔진 (no unsafe)
│   ├── src/                   model, timeline, commands, editor, export, platform, bridge,
│   │                          render_plan(렌더 그래프), progress(진행률), probe(프로브)
│   ├── tests/                 편집 시나리오 + 저장/내보내기 통합 테스트
│   └── examples/              demo_project
└── app/                       Flutter UI + 네이티브 미디어 경계
    ├── lib/                   main, bridge_api(상태 관리), core_bridge, commands, models, theme
    ├── lib/media/             media_platform_bridge(MethodChannel/EventChannel)
    ├── lib/editor/            editor_screen, workspace, editor_section, preview_panel,
    │                          timeline_view, inspector_panel, preview_engine
    ├── lib/src/rust/          flutter_rust_bridge 코드젠 바인딩(커밋됨)
    ├── lib/rust_core_loader.dart  플랫폼별 코어 라이브러리 로딩
    ├── test/                  FFI 실연결 + UI 흐름/토큰/반응형 레이아웃 위젯 테스트(72개)
    └── native/                apple(Swift) · android(Kotlin) · windows(C++) 미디어 엔진
```

## 설계 요약

| 질문 | 답 |
|---|---|
| 편집 상태는 어디에? | Dart가 소유. Rust는 **순수 함수 + JSON**만 받는다(핫 리로드/다중 창/테스트에 유리). |
| 시간 단위? | 정수 ms. 프레임 정렬은 UI 경계에서만(`snap_to_frame`). |
| 되돌리기는? | 모든 편집이 `EditCommand`를 통과하고, 각 커맨드가 **역 커맨드**를 돌려준다. |
| 물리 자원은? | 미디어/GPU는 플랫폼 API(VideoToolbox·MediaCodec·Media Foundation·FFmpeg). 코어는 **렌더 그래프**만 만든다. |
| 플랫폼 간 일치? | 같은 그래프 + 같은 `graph_digest`. 프레임 경계 규칙을 코어와 렌더러가 공유한다. |
| 워터마크? | 없음이 제품 원칙. `ExportSettings.watermark=true`는 검증 단계에서 **거부**되고, 인자 생성기에 워터마크 경로가 없다(테스트로 고정). |

## 라이선스

Rust 코어: MIT OR Apache-2.0.
FFmpeg을 배포에 포함할 경우 LGPL 조건과 코덱 특허를 별도로 검토해야 한다
(`ARCHITECTURE.md` 13절 리스크).
