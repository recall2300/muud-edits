# muud-edits 아키텍처

> Meta **Edits**를 대체할 크로스플랫폼 숏폼 영상 편집기.
> Flutter(UI) + Rust(코어 엔진) + OS 하드웨어 가속 미디어 파이프라인.
> Windows · macOS · Android · iOS.

이 문서는 "무엇을 어떤 경계로 나눌 것인가"를 정한다. 각 경계의 근거와,
지금 코드에 **이미 구현된 것(✅)** 과 **설계만 된 것(🔜)** 을 구분해 적었다.

---

## 1. 목표와 비목표

### 목표 (1단계 = MVP)
1. 컷/트림/분할, 멀티트랙 타임라인, 텍스트/자막, 오디오 볼륨 → **워터마크 없는 내보내기**
2. 4개 플랫폼에서 같은 프로젝트 파일(`.muudproj`)이 열리고 같은 결과가 나온다.
3. 미디어 디코드/인코드는 **플랫폼 하드웨어**(VideoToolbox · MediaCodec · Media Foundation)를 1순위로 쓴다.
4. 편집은 **되돌리기가 항상 가능**하고, 앱이 죽어도 프로젝트가 남는다.
5. 계정/서버 없이 로컬에서 완결된다(프라이버시 + 오프라인).

### 비목표 (1단계에서 하지 않는다)
* 클라우드 렌더링, 협업 편집, 계정 동기화
* 모션 그래픽/키프레임 애니메이션(2단계)
* 4K 60fps 실시간 프리뷰(프록시로 대응, 4K는 2단계 최적화 대상)
* 전문 NLE급 오디오 믹서(EQ/컴프레서)

---

## 2. 핵심 결정과 근거

| 결정 | 선택 | 대안 | 근거 |
|---|---|---|---|
| UI | Flutter | 네이티브 2벌(스위프트/코틀린), React Native | 타임라인·제스처·테마를 한 벌로. Impeller로 60/120fps 스크롤이 가능해졌다. |
| 코어 | Rust 크레이트(`rust_core`) | Dart로 전체 구현, C++ | 메모리 안전 + FFI 비용 낮음 + 4플랫폼 동일 바이너리 로직. Dart로 인코딩 루프를 돌리면 GC/isolate 복사 비용이 크다. |
| 브리지 | `flutter_rust_bridge` (2.x) | 직접 dart:ffi, platform channel | 코드 생성 + 에러 전파 + async 지원. 처음부터 직접 FFI 바인딩을 손으로 쓰는 비용이 더 크다. |
| 편집 모델 | **커맨드 + 역 커맨드** | 전체 상태 스냅샷, CRDT | 스냅샷은 메모리 폭증, CRDT는 1단계에 과잉. 역 커맨드는 undo/redo/로그/매크로를 한 구조로 해결. |
| 시간 단위 | 정수 ms (`i64`) | 초 단위 f64 | 부동소수 누적 오차와 프레임 경계 비교 문제를 원천 차단. 프레임 정렬은 UI 경계에서만. |
| 미디어 | 플랫폼 네이티브 1순위, FFmpeg 폴백 | FFmpeg 단일 경로 | 하드웨어 인코더를 쓰면 4K 익스포트가 5~10배 빠르고 발열/배터리가 낮다. FFmpeg는 필터·폴백·검증용. |
| 프리뷰 | 디코드 → 합성 → Flutter Texture | 매 프레임 이미지를 Dart로 복사 | 프레임을 Dart 힙으로 복사하면 1080p 기준 프레임당 8MB 복사가 발생한다. |
| 상태 소유 | **Dart가 소유**, Rust는 무상태 함수 | Rust 싱글턴 상태 | 핫 리로드·다중 창·테스트·크래시 복구가 쉬워진다. |

### 왜 "역 커맨드"인가 (조금 더)
```text
사용자: [클립 분할]
  커맨드 SplitClip{clip: clp-3, at: 1500}
     └─ apply → { left.clip_3 (0~1500), new clp-9 (1500~4000) }
        returns → Batch[ RemoveClip(clp-9), TrimClip(clp-3, end=4000) ]
히스토리: undo 스택에 (커맨드, 역커맨드) 쌍을 push
[Ctrl+Z] → 역커맨드 apply → redo 스택으로 이동
[Ctrl+Shift+Z] → 원 커맨드 apply → 새 역커맨드 계산 → undo 스택
```
* 모든 커맨드는 **검증 → 변이** 순서라 실패해도 상태가 남지 않는다.
  (여러 커맨드를 묶는 `Batch`만 복제본에서 먼저 시험 적용.)
* 역커맨드도 같은 규칙을 따르므로 "되돌리기의 되돌리기"가 자동으로 성립한다.
* 히스토리는 직렬화된다 → 프로젝트를 저장하면 undo 스택도 함께 저장/복원된다.

---

## 3. 계층 구조

```text
┌──────────────────────────────────────────────────────────────────────┐
│  Flutter UI (Dart)                                                   │
│  · 타임라인/플레이어/인스펙터 위젯, 제스처, 단축키, 테마                 │
│  · EditorState(불변) + CommandBus. UI는 오직 커맨드만 보낸다.           │
└───────────────▲──────────────────────────────────┬───────────────────┘
                │ 상태(JSON) + 요약                 │ 커맨드(JSON)
┌───────────────┴──────────────────────────────────▼───────────────────┐
│  flutter_rust_bridge  (FFI, 4플랫폼 공통)                             │
│  · String ↔ String(JSON) 경계, async로 UI 스레드 블로킹 방지           │
└───────────────▲──────────────────────────────────┬───────────────────┘
                │                                  │
┌───────────────┴──────────────────────────────────▼───────────────────┐
│  rust_core (Rust, 순수 로직·no unsafe)                                │
│  ├ model      Project / Track / Clip / SubtitleItem / ExportSettings │
│  ├ timeline   스플릿 지점, 프레임 양자화, 스냅, 타임코드                  │
│  ├ commands   EditCommand(19종, Batch 포함) · History(undo/redo, limit 200)     │
│  ├ editor     파사드: apply/undo/redo + 편의 빌더                        │
│  ├ project_io .muudproj JSON, schema_version, SRT/VTT                    │
│  ├ export     설정 검증 → 인코더 선택 → ffmpeg 인자/계획                 │
│  ├ render_plan 타임라인 → 결정적 RenderGraph(세그먼트/오디오/자막/지문)    │
│  ├ progress   ExportProgress · ExportJobState(취소 요청/확정)            │
│  ├ probe      MediaProbeInfo 정규화·검증(플랫폼 프로브 결과)             │
│  └ platform   플랫폼별 미디어/GPU 역량 표                                │
└───────────────▲──────────────────────────────────┬───────────────────┘
                │ 프레임 요청/완료                   │ 렌더 그래프(JSON) + 이벤트
┌───────────────┴──────────────────────────────────▼───────────────────┐
│  Platform media layer (app/native/, 플랫폼 embedder 플러그인)            │
│  macOS/iOS : AVFoundation + VideoToolbox   → AVMutableVideoComposition │
│  Windows   : ffmpeg 프로세스(+ Media Foundation 후속)                    │
│  Android   : MediaMetadataRetriever + Media3 Transformer               │
│  폴백/검증  : FFmpeg (디코드, 필터그래프, 최종 mux)                      │
└───────────────▲──────────────────────────────────┬───────────────────┘
                │ GPU 텍스처                        │
┌───────────────┴──────────────────────────────────▼───────────────────┐
│  Flutter renderer (Impeller: Metal / D3D11(Vulkan) / Vulkan/GLES)     │
│  · PlatformView/ExternalTexture로 합성 결과를 위젯 트리에 붙인다        │
└──────────────────────────────────────────────────────────────────────┘
```

핵심은 **"시간과 상태는 Rust, 픽셀은 플랫폼, 배치는 Flutter"** 다.
경계를 넘는 것은 JSON 커맨드(작다)와 텍스처 핸들(포인터 크기)뿐이고,
프레임 데이터는 절대 브리지를 넘지 않는다.

---

## 4. 데이터 모델 (`rust_core/src/model.rs`)

```text
Project
 ├ id, name, created_at_ms, modified_at_ms
 ├ resolution(1080x1920), fps(30), sample_rate(48000)
 ├ tracks: Vec<Track>            ← 아래에서 위로 그린다
 │   ├ kind: Video | Audio | Overlay        (Overlay만 겹침 허용)
 │   └ clips: Vec<Clip>  (timeline_offset_ms 정렬 유지)
 ├ subtitles: SubtitleTrack { style, items: Vec<SubtitleItem> }
 ├ export: ExportSettings
 └ ids: IdSeq                   (프로젝트 단위 단조 증가 발급기)
```

### Clip
| 필드 | 의미 | 불변식 |
|---|---|---|
| `source_path` | 원본 파일 | 미디어 클립은 비어 있을 수 없음 |
| `start_ms` / `end_ms` | 소스 구간 [start, end) | `0 ≤ start < end ≤ source_duration_ms` |
| `timeline_offset_ms` | 타임라인 배치 위치 | `≥ 0`, 같은 트랙 내 비겹침 |
| `speed` | 0.25 ~ 4.0 | 타임라인 길이 = `(end-start)/speed` |
| `volume` / `opacity` | 0.0 ~ 2.0 / 0.0 ~ 1.0 | |
| `fade_in_ms` / `fade_out_ms` | 게인 램프 | `gain_at(t)`로 조회 |
| `text: Option<TextOverlay>` | 텍스트 클립의 내용/스타일 | 텍스트 클립은 내용 필수 |
| `source_duration_ms` | 프로브 결과(선택) | 트림 검증에 사용 |

**speed가 있는 클립의 시간 매핑**
```text
timeline_duration = round((end - start) / speed)
source_time_at(t) = start + round((t - offset) * speed)
```
분할은 항상 `source_time_at`을 거치므로 2x 클립을 1초 지점에서 잘라도
소스는 2초 지점에서 잘린다(테스트 `split_respects_speed`).

### 자막을 클립과 분리한 이유
1. Whisper 자동 자막은 **시간 기준**으로 나오고 클립 경계와 무관하다.
2. SRT/VTT 사이드카로 그대로 내보낼 수 있어야 한다.
3. 렌더러는 자막을 항상 최상위에 합성하면 되므로 z-order 논쟁이 없다.

### 불변식 검증
`Project::validate()`가 fps/해상도/클립 범위/트랙-클립 종류/겹침을 점검한다.
저장 직전과 파일을 불러온 직후에 호출한다(문제는 문자열 목록으로 돌려준다).

---

## 5. 편집 커맨드 (`rust_core/src/commands.rs`)

| 커맨드 | 되돌리기 |
|---|---|
| `AddTrack` / `RemoveTrack` / `RenameTrack` / `SetTrackState` | 대칭 |
| `AddClip` / `RemoveClip` | 대칭(제거 시 클립 스냅샷 보관) |
| `TrimClip` | 이전 인/아웃/오프셋으로 복원 |
| `MoveClip` | 반대 방향 이동(트랙 간 포함) |
| `SplitClip` | `Batch[RemoveClip(오른쪽), TrimClip(왼쪽, 원래 끝)]` |
| `SetClipSpeed` / `Volume` / `Opacity` / `Enabled` / `Text` / `Fades` | 이전 값 복원 |
| `AddSubtitle` / `UpdateSubtitle`(패치) / `RemoveSubtitle` | 대칭 |
| `Batch` | 역순 역 커맨드 묶음, 실패 시 원자적 |

* 히스토리 한도 기본 200(메모리/응답성 균형). 초과 시 가장 오래된 것부터 버린다.
* 새 편집을 하면 redo 스택은 비워진다(일반 편집기 관행).
* 실패한 undo는 스택을 원상복구한다 → 히스토리와 상태가 어긋나지 않는다.
* `CommandOutcome`(길이/클립 수/undo 가능 여부)을 매 호출마다 돌려줘
  UI가 상태를 다시 계산하지 않고 툴바만 갱신할 수 있게 한다.

### MVP에서 의도적으로 뺀 것
**리플(ripple) 편집**: 클립을 늘리거나 줄일 때 뒤 클립을 자동으로 밀지 않는다.
2단계에서 `TrimClip`에 `ripple: bool`을 추가하고 역커맨드에 이동 목록을 담는 방식으로 확장한다.
(지금은 겹치면 명확히 거부한다 — 사용자가 데이터를 잃는 것보다 낫다.)

---

## 6. 브리지 설계 (Flutter ↔ Rust)

### 경계의 형태
```dart
// Dart 측 (요약)
final state = await BridgeApi.createProject(name: '상하이', width: 1080, height: 1920, fps: 30);
final next  = await BridgeApi.applyCommand(state, {'type': 'split_clip', 'track_id': t, 'clip_id': c, 'at_timeline_ms': 1500});
```

```rust
// Rust 측 (rust_core/src/bridge.rs)
pub fn create_project(name: &str, width: u32, height: u32, fps: u32) -> Result<String, String>;
pub fn apply_command(state_json: &str, command_json: &str) -> Result<String, String>;
pub fn undo(state_json: &str) -> Result<String, String>;
pub fn export_plan(state_json: &str, settings_json: &str, platform_id: &str) -> Result<String, String>;
```

* 모든 함수는 **JSON 문자열 in / JSON 문자열 out**. 실패는 `{ok:false, error:{code, message}}`.
* `code`는 UI 분기용 안정 키(`overlap`, `track_locked`, `watermark_not_allowed` …).
* 상태는 Dart가 소유한다. Rust에는 아무 상태도 남지 않는다 → 핫 리로드해도 안전.

### 왜 타입드 바인딩이 아니라 JSON인가
`EditCommand`는 18종 태그드 유니온이고 모델은 계속 커진다. flutter_rust_bridge의
타입 생성으로 이 전체를 노출하면 커맨드 하나 추가할 때마다 Dart 코드를 다시 만들어야 한다.
**초기 계약을 얇게 유지**하고, UI가 안정되면 자주 쓰는 함수(`create_project`, `apply_command`)만
타입드 시그니처로 승격한다. 이때 Rust 내부 구현은 그대로다.
(공개 타입 `Editor`, `EditCommand`, `Project`는 이미 `Serialize/Deserialize`라 그대로 노출 가능.)

### 스레딩
| 작업 | 위치 | 이유 |
|---|---|---|
| 커맨드 적용/undo | Rust 워커 스레드(FFI async) | JSON 파싱 + 검증은 수 ms. UI 프레임을 막지 않는다. |
| 프로젝트 저장 | Rust 워커 | 파일 I/O |
| 디코드/합성 | 플랫폼 미디어 스레드 | 하드웨어 디코더 큐 |
| 프레임 표시 | Flutter raster 스레드 | 텍스처만 받는다 |

---

## 7. 재생(프리뷰) 파이프라인 ✅(v0.1.4)

v0.1.3은 **"타임라인 시각 하나 → 실제 재생 중인 클립 하나"** 로 단순화했고,
v0.1.4는 같은 구조 위에서 **끊김 없는 이어 재생**을 목표로 시간 기준을 바꿨다.
전체 프레임 합성기(GPU 합성·프록시 캐시)는 2단계 과제로 남기고, 지금은 사용자가
가장 먼저 기대하는 **영상 프레임과 소리**를 확실하게 재생하는 데 집중했다.

```text
playhead t
  └ resolvePreviewSelection(state, t)        ← 순수 함수(lib/editor/preview_engine.dart)
        · visualClip: 위 트랙 우선 영상/이미지 클립(숨김·비활성 제외)
        · sourceMs:  start_ms + (t - offset) × speed   (코어와 같은 규칙)
        · audioClip: 별도 오디오 트랙 클립(있으면 동시 재생)
        ├ (1) 플랫폼 플레이어 하나에 해당 파일을 물린다
        │      video_player: Android ExoPlayer · iOS/macOS AVFoundation
        │      video_player_win: Windows Media Foundation
        ├ (2) 플레이어를 sourceMs 로 시크 — 사용자가 옮겼을 때와 클립이 바뀔 때만
        ├ (3) 재생 중 재생 헤드 = **플레이어 위치**(플레이어가 시계)
        │      보고된 위치(약 100ms 간격) 사이만 벽시계로 이어 붙인다(MediaPositionClock)
        │      빈 구간·이미지 클립에서만 벽시계로 흐른다
        └ (4) 텍스트/자막은 Dart 오버레이로 시각 범위에 맞춰 그린다
```

* **재생 중 시크 금지**: 같은 클립을 이어 재생하는 동안에는 `seekTo`를 부르지 않는다.
  시크는 ① 사용자가 스크럽·탭·프레임 이동으로 옮겼을 때 ② 클립이 바뀌었을 때(인점이
  현재 위치와 다를 때) ③ 새로 연 파일의 첫 위치가 어긋났을 때만.
* **클립 경계**: 경계 1.5초 전에 다음 클립 컨트롤러를 미리 열어 둔다(프리로드).
  같은 파일을 자른 클립이면 컨트롤러를 유지하고 인점으로만 시크한다.
* **경량 UI**: 재생 헤드는 `ValueNotifier<int>`로 알리고, 구독하는 곳은 타임코드
  텍스트·타임라인 플레이헤드 선·자막/텍스트 오버레이뿐이다. 재생 중
  `EditorController`의 플레이헤드는 바꾸지 않으므로 화면 전체가 리빌드되지 않는다
  (일시정지·편집 동작 시점에 한 번 커밋한다).
* **배속·볼륨**: 클립 speed는 플레이어 `playbackSpeed`, volume은 `setVolume(0~1)`로 반영.
  값이 바뀌지 않으면 플랫폼을 다시 부르지 않는다.
* **정확도 기준**: 시크 허용 오차 90ms(정지), 재생 중 같은 클립 허용 오차 1200ms(안전장치).
* `resolvePreviewSelection`이 순수 함수라 단위 테스트로 트림·분할·빈 구간을 직접 검증하고,
  재생 엔진 테스트는 "이어 재생 중 시크 횟수"로 끊김 여부를 검증한다.

남은 2단계 과제: 여러 레이어 동시 합성, 프록시 캐시, 오디오 마스터 클록, 자막 burn-in.

---

## 8. 내보내기 파이프라인 ✅(계획·그래프) / ✅(네이티브 1차 구현) / 🔜(기기 검증)

`rust_core/src/export.rs`는 "무엇으로 어떻게 인코딩할지"를 결정하고 검증한다.

```text
ExportSettings { resolution, fps, bitrate, gop, codec, audio, container, hardware, range,
                 burn_in_subtitles, watermark=false }
   │ validate()               ← 워터마크 true면 즉시 거부
   │ encoder_for(platform)    ← 플랫폼 네이티브 인코더 선택 (불가하면 사유와 함께 폴백)
   └ plan() → ExportPlan { encoder, ffmpeg_args, notes, summary }
```

### 8.1 결정적 렌더 그래프 (`render_plan.rs`) — 코어와 네이티브의 계약

내보내기 실행의 입력은 `ExportPlan`이 아니라 **`RenderGraph`**다. 코어가 타임라인을
"렌더러가 그대로 소비하는 계획"으로 컴파일한다.

```text
Project + ExportSettings + Platform
   └ RenderGraph::compile()
        ├ resolution/fps/frame_count/duration_ms   ← 출력 규격(내보내기 구간 반영)
        ├ segments[]        {layer, clip, kind, source_in/out, render_start/end,
        │                     frame_start/end, speed, opacity_curve, text}
        ├ audio_segments[]  {source, render_start/end, gain, gain_curve(curve points), muted}
        ├ subtitles         {enabled, style, items[{frame range, style, display_text}]}
        ├ encoder, container, watermark=false
        └ graph_digest      ← 내용의 FNV-1a 64 지문(결정성 검증/캐시 키)
```

* **시간**: 모든 값은 정수 ms. `frame = round(ms × fps / 1000)` 규칙을 코어와 렌더러가 공유한다.
* **결정성**: 같은 프로젝트·설정·플랫폼이면 JSON과 `graph_digest`가 바이트 단위로 같다
  (클립 삽입 순서가 달라도 정렬 후 같다 — 테스트 `graph_is_deterministic_and_order_independent`).
* **범위**: `ExportSettings.range`는 그래프 단계에서 잘라 `render_*` 시각으로 당긴다.
  타임라인 밖 구간은 `invalid_range`로 거부한다.
* **합성 계약**: `layer` 오름차순, `opacity_curve` 선형 보간, 오디오는 전 구간 합산,
  자막은 `enabled`일 때 번인. 네이티브 엔진은 이 계약만 구현하면 4플랫폼이 같은 결과를 낸다.

### 8.2 진행률과 취소 (`progress.rs`)

플랫폼 이벤트(AVAssetExportSession progress, Media3 progress, ffmpeg `frame=`)를
하나의 상태 기계로 정규화한다.

```text
Queued → Preparing → Rendering → Finalizing → Completed
   └──────────┴───────────┴────────────┴──────────────→ Canceled (요청 → 확정)
                              └──────────────────────→ Failed
```

* 취소는 **요청**(`cancel_request`)과 **확정**(`canceled`)이 나뉜다. 렌더 중에는 네이티브가
  파일을 정리할 시간이 필요하므로 요청만으로 끝내지 않는다.
* `ExportProgress`는 `fraction/percent/eta_ms/state_label`을 계산해 UI가 그대로 쓴다.
* 진행률 단위가 다른 플랫폼(0~1, 프레임 수, ffmpeg 라인)을 `completed_frames`로 통일한다.

### 8.3 실행 경로

| 경로 | 언제 | 방법 |
|---|---|---|
| **네이티브 (1순위)** | 항상 | 그래프를 플랫폼 엔진에 넘긴다: macOS/iOS `AVMutableComposition`+`AVAssetExportSession`, Android Media3 `Transformer`, Windows `ffmpeg` 프로세스(또는 MF) |
| **FFmpeg 폴백** | 네이티브 실패, 특수 코덱/필터 | `ExportPlan.ffmpeg_args`를 그대로 프로세스에 전달 |

네이티브 구현 위치와 세부 한계는 `app/native/README.md`에, 연결 방법은 `docs/LOCAL_SETUP.md`에 있다.

* 워터마크: **없음이 제품 원칙**. `ExportSettings.watermark`는 `true`면 검증에서 거부되는
  잠금장치이고, 인자 생성기에 워터마크/`drawtext` 필터를 넣는 코드 경로 자체가 없다
  (테스트 `ffmpeg_args_have_no_watermark_filter`).
* `-movflags +faststart`로 SNS 업로드 즉시 재생 가능한 MP4를 만든다.
* 오디오는 항상 48kHz로 통일(플랫폼 인코더 편차 회피).
* 자막은 별도 소프트 트랙이 아니라 **영상에 번인**한다(숏폼 업로드 호환).

---

## 9. 플랫폼별 빌드 & 하드웨어 코덱 전략

| | macOS | Windows | Android | iOS |
|---|---|---|---|---|
| UI 빌드 | Flutter macOS embedder | Flutter Windows embedder | Flutter Android | Flutter iOS |
| 코어 빌드 | cdylib(`libmuud_edits_core.dylib`) → `FlutterMacOS`에 embed | `muud_edits_core.dll` | `libmuud_edits_core.so` (arm64-v8a, armeabi-v7a) | `muud_edits_core.a` (staticlib) |
| 디코드 | VideoToolbox (`AVAssetReader`) | Media Foundation (`IMFSourceReader`, DXVA) | MediaCodec + `SurfaceTexture` | VideoToolbox |
| 인코드 | `h264_videotoolbox` / `hevc_videotoolbox` / `prores_videotoolbox` | `h264_mf` / `hevc_mf` (+ NVENC/QSV 선택) | `h264_mediacodec` / `hevc_mediacodec` | `h264_videotoolbox` / `hevc_videotoolbox` |
| 합성 | Metal (`MTLCommandQueue`) | D3D11 | OpenGL ES 3.x / Vulkan | Metal |
| Flutter 연결 | `FlutterTexture` | `FlutterTexture` | `SurfaceProducer`/ExternalTexture | `FlutterTexture` |
| 최소 버전 | macOS 12 | Windows 10 1909 | API 26 (8.0) | iOS 16 |
| 툴체인 | Xcode 16+, `cargo build --target aarch64-apple-darwin` | VS 2022 (Desktop C++), `x86_64-pc-windows-msvc` | NDK r27, `aarch64-linux-android` | Xcode 16+, `aarch64-apple-ios` |

### 플랫폼별 주의점
* **macOS**: 앱 샌드박스에서 사용자가 고른 파일은 security-scoped bookmark로 접근 권한을
  유지해야 재시작 후에도 프로젝트가 열린다. 하드웨어 인코더는 세션당 1~2개 제한이 있어
  병렬 익스포트를 하지 않는다.
* **Windows**: Media Foundation MFT는 **설치된 드라이버에 따라 유무가 다르다**.
  시작 시 `MFTEnumEx`로 H.264/HEVC 인코더 존재를 확인하고, 없으면 FFmpeg 폴백을 쓴다.
  HEVC는 Windows에서 "HEVC 비디오 확장" 설치가 필요할 수 있다(설치 안내 UI 필요).
* **Android**: 기기 편차가 가장 크다. `MediaCodecList`로 (mime, 해상도, 비트레이트) 지원 여부를
  **런타임에** 확인하고, 없으면 H.264로 낮춘다. AV1 인코딩은 사실상 없다고 보고 소프트웨어 폴백.
  4K 인코딩 중 발열 스로틀링 → 1080p 권장 안내.
* **iOS**: 백그라운드에서 긴 익스포트를 하려면 `BGProcessingTask`. ProRes는 일부 기기만.
  메모리 제약(iPhone 8GB) 때문에 4K 다중 트랙은 프레임 단위 스트리밍 합성을 강제한다.

---

## 10. 저장 포맷 `.muudproj` ✅

```json
{
  "schema_version": 1,
  "id": "prj-1764000000000",
  "name": "상하이 마라톤 브이로그",
  "resolution": { "width": 1080, "height": 1920 },
  "fps": 30,
  "tracks": [
    { "id": "trk-0001", "name": "Video 1", "kind": "video",
      "clips": [ { "id": "clp-0003", "source_path": "/media/IMG_0412.MOV",
                   "kind": "video", "start_ms": 0, "end_ms": 12000,
                   "timeline_offset_ms": 0, "speed": 0.8, "volume": 1.0,
                   "opacity": 1.0, "fade_in_ms": 0, "fade_out_ms": 0,
                   "enabled": true } ] }
  ],
  "subtitles": { "enabled": true, "style": { "...": "..." }, "items": [] },
  "export": { "codec": "h264", "container": "mp4", "watermark": false, "...": "..." },
  "ids": { "next": 12 }
}
```

* **pretty JSON**: diff/디버깅/부분 복구에 유리. 크기는 zstd로 감싸 저장 가능(2단계).
* `schema_version`이 코드보다 높으면 **읽지 않고 거부**한다(모르는 필드를 잃는 것보다 안전).
* 모든 신규 필드는 `#[serde(default)]`라 구버전 파일이 그대로 열린다.
* 미디어 경로: 저장 시 절대 경로를 쓰되, 프로젝트 폴더 기준 상대 경로가 있으면 그것을 우선한다(2단계).
* `.muudproj` 옆에 `.srt`/`.vtt`를 함께 내보낼 수 있다(`Editor::save_srt`).

---

## 11. 로드맵

### 1단계 — MVP (현재)
| 기능 | 상태 |
|---|---|
| 프로젝트/트랙/클립 모델, 불변식 | ✅ |
| 컷·트림·분할·이동·삭제 | ✅ (코어) |
| 멀티트랙(Video/Audio/Overlay) | ✅ (코어) |
| 텍스트 오버레이 + 자막 + SRT/VTT | ✅ (코어) |
| 오디오 볼륨/페이드 | ✅ (코어) |
| Undo/Redo + 히스토리 저장 | ✅ (코어) |
| 프로젝트 저장/불러오기 | ✅ (코어) |
| 내보내기 계획(워터마크 없음, HW 인코더 선택) | ✅ (코어) |
| Flutter 편집 화면(타임라인/프리뷰/인스펙터) | 🔜 스캐폴딩 완료 |
| 실제 디코드·합성·인코딩 | 🔜 플랫폼 레이어 |
| 미디어 프로브(길이/해상도/fps) | 🔜 |

**MVP 수용 기준**
1. 4개 플랫폼에서 같은 `.muudproj`를 열면 타임라인이 1ms 단위로 동일하다.
2. 30번의 편집 후 undo 30번 → 초기 JSON과 트랙/자막이 완전히 일치한다.
3. 편집 중 앱 강제 종료 → 재실행 시 마지막 저장본이 열린다.
4. 1080x1920, 30fps, 3트랙 1분 프로젝트를 iPhone 13 / 중급 안드로이드에서
   하드웨어 인코딩으로 **실시간의 30% 이내**(= 익스포트 시간 ≤ 영상 길이 × 0.3)에 내보낸다.
5. 내보낸 파일에 워터마크가 없다(픽셀 검사 + 인자 검사).

### 2단계 — 자동화와 표현력
1. **자동 자막**: Whisper.cpp(로컬, 오프라인) → `add_auto_subtitles`로 일괄 삽입.
   ✅ 코어 API는 이미 있음. 필요: 모델 번들(양자화 tiny/base ≈ 40~150MB) + VAD로 무음 구간 스킵.
2. **배경 제거/컷아웃**: 인물 세그멘테이션(Core ML / MediaPipe / ONNX Runtime) →
   마스크를 GPU에서 합성. 프레임 단위라 실시간성 예산이 빡빡하다(1080p에서 10ms 이내 목표).
3. **필터/트랜지션**: LUT + 셰이더. 트랜지션은 두 클립이 겹치는 구간의 알파/변형 함수로 모델링
   (`Transition{kind, duration_ms}`를 인접 클립에 붙인다).
4. **키프레임 애니메이션**: `Animated<f32>`로 opacity/scale/position을 시간 함수로.
   커맨드에는 `SetKeyframe`/`RemoveKeyframe` 추가(역커맨드 동일).
5. **리플 편집 + 자기 조립(B-roll 자동 배치)**.

---

## 12. 성능 예산과 리스크

| 항목 | 예산 | 근거 |
|---|---|---|
| 타임라인 스크럽 | 60fps (16.6ms/프레임) | 프록시 720p 디코드 + GPU 합성 |
| 커맨드 적용 | < 5ms | 순수 메모리 연산. 히스토리 200개 한도 |
| 프로젝트 저장 | < 50ms (1분 프로젝트) | JSON ~100KB |
| 메모리 | < 400MB (1080p 3트랙) | 프레임 링 버퍼 ±2초 |
| 익스포트 | 실시간의 20~30% | 하드웨어 인코더 |

| 리스크 | 영향 | 대응 |
|---|---|---|
| **FFmpeg 라이선스** | GPL 빌드를 배포하면 앱 전체 GPL | 기본은 LGPL 빌드(`--disable-gpl`), x264/x265는 **별도 프로세스**로 실행하거나 하드웨어 인코더만 사용 |
| 코덱 특허(H.264/HEVC) | 배포 국가별 royalty | 플랫폼 OS 인코더 사용 시 OS 라이선스에 의존. 순수 소프트웨어 배포는 법률 검토 필요 |
| Android 기기 편차 | 특정 기기 익스포트 실패 | 런타임 코덱 프로브 + 자동 폴백 + 실패 리포트 |
| iOS 메모리 | 4K 다중 트랙 OOM | 프레임 스트리밍 합성, 1080p 권장 |
| HEVC 재생 미지원(Windows) | 결과물이 안 열림 | 기본 H.264, HEVC는 확장 설치 안내 |
| 시계 드리프트 | 영상/음성 밀림 | 오디오 마스터 클록 + PTS 재계산 |

---

## 13. 디렉터리 구조

```text
muud-edits/
├── ARCHITECTURE.md          ← 이 문서
├── README.md                ← 5분 안에 돌려보기
├── .gitignore
├── docs/
│   ├── LOCAL_SETUP.md       ← 플랫폼별 개발 환경 구축 순서
│   └── BRIDGE_CONTRACT.md   ← JSON 커맨드/응답 스키마
├── rust_core/               ← ✅ 동작하는 코어 엔진 (cargo test 141개)
│   ├── Cargo.toml           ← package muud-core / lib muud_core
│   ├── src/lib.rs           ← 모듈 선언, CORE_VERSION
│   ├── src/{ids,error,model}.rs
│   ├── src/{timeline,commands,editor,subtitles}.rs
│   ├── src/{export,platform,project_io,bridge}.rs
│   ├── src/render_plan.rs   ← 타임라인 → 결정적 RenderGraph
│   ├── src/progress.rs      ← ExportProgress/ExportJobState/취소 상태 기계
│   ├── src/probe.rs         ← MediaProbeInfo 정규화/검증
│   ├── tests/{editing_flow,persistence_export}.rs
│   └── examples/demo_project.rs
└── app/                     ← Flutter 스캐폴딩
    ├── pubspec.yaml
    ├── analysis_options.yaml
    ├── flutter_rust_bridge.yaml
    ├── lib/main.dart        ← 앱 진입점(테마·홈)
    ├── lib/theme.dart       ← 팔레트/테마
    ├── lib/models.dart      ← 브리지 JSON 파싱(불변 뷰 모델 + MediaProbe/ExportProgress)
    ├── lib/commands.dart    ← 커맨드 빌더(JSON)
    ├── lib/core_bridge.dart ← CoreBridge 인터페이스 + FRB 구현
    ├── lib/bridge_api.dart  ← EditorController(상태 관리·액션·내보내기 흐름)
    ├── lib/media/media_platform_bridge.dart ← MethodChannel/EventChannel 미디어 경계
    ├── lib/editor/{editor_screen,preview_panel,timeline_view,inspector_panel}.dart
    ├── lib/src/rust/        ← flutter_rust_bridge 코드젠 바인딩(커밋됨)
    ├── lib/rust_core_loader.dart ← 플랫폼별 코어 라이브러리 로딩
    └── native/              ← 4플랫폼 네이티브 미디어 엔진(스캐폴딩 + 파이프라인)
        ├── README.md        ← 채널 계약·연결·한계
        ├── apple/           ← macOS+iOS Swift (AVFoundation/VideoToolbox)
        ├── android/         ← Kotlin (MediaMetadataRetriever + Media3 Transformer)
        └── windows/         ← C++ (ffmpeg/ffprobe 프로세스 파이프라인)
```

---

## 14. 테스트 전략

| 층 | 방법 | 현재 |
|---|---|---|
| 코어 로직 | `cargo test` — 순수 함수 + 커맨드 왕복 | ✅ 141개 |
| 렌더 그래프 | 프레임 경계/구간/결정성/다이제스트 | ✅ |
| 진행률 상태 | 단계 전환·취소 요청/확정·종료 상태 불변 | ✅ |
| 프로브 | 플랫폼 JSON 정규화·검증·이미지 판정 | ✅ |
| 커맨드 불변식 | 실패한 커맨드는 상태를 바꾸지 않는다 | ✅ |
| 저장 호환성 | 라운드트립 + 스키마 가드 + 누락 필드 기본값 | ✅ |
| 내보내기 매트릭스 | 5플랫폼 × 4코덱 조합 검증, 워터마크 부재 | ✅ |
| 브리지 계약 | JSON 문자열 왕복(실패 코드 포함) | ✅ |
| 통합 파이프라인 | 편집 → 그래프 → 진행률/취소 → 프로브 (`tests/render_pipeline.rs`) | ✅ 7개 |
| UI | 위젯 테스트(타임라인 드래그 → 커맨드 발행) | 🔜 Flutter 설치 후 |
| 통합 | 실제 미디어 3종으로 익스포트 후 ffprobe 검증 | 🔜 |

`cargo test`는 미디어 파일 없이 돈다(경로만 문자열). 실제 인코딩 검증은 2단계 CI에서
샘플 클립을 받아 ffprobe로 프레임 수/길이/코덱을 확인한다.

---

## 15. 다음 단계 체크리스트

- [x] 코어 모델/커맨드/undo/redo/저장/내보내기 계획
- [x] Flutter 앱 스캐폴딩(타임라인·프리뷰·인스펙터 뼈대)
- [x] 결정적 렌더 그래프(RenderGraph) + 진행률/프로브 모델 + 브리지 API
- [x] 4플랫폼 네이티브 미디어 레이어 스캐폴딩 + 핵심 파이프라인 코드
- [x] Flutter `MediaPlatformBridge`(MethodChannel/EventChannel) + 파일 선택·프로브·진행률 UI
- [ ] `flutter_rust_bridge_codegen generate`로 바인딩 생성 (Flutter 설치 후)
- [ ] `flutter create`로 플랫폼 폴더 생성 후 네이티브 파일 연결(LOCAL_SETUP 4절)
- [ ] 실기기 검증: macOS/Xcode · Windows/MSVC+ffmpeg · Android Studio · iOS
- [ ] 다중 레이어/정지 이미지 합성(플랫폼별) 및 자막 번인 Android 확장
- [ ] 프리뷰 프레임 파이프라인 + 프록시 캐시
- [ ] 자동 저장(30초/idle 2초) + 크래시 복구
- [ ] 2단계: Whisper 자동 자막 → 배경 제거 → 필터/트랜지션
