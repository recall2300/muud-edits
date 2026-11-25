# 네이티브 미디어 레이어 (4플랫폼)

이 폴더는 Flutter 앱이 **OS 미디어 엔진**과 대화하는 부분이다. Rust 코어가 만든
[`RenderGraph`](../../rust_core/src/render_plan.rs)를 그대로 소비해 실제 영상을 만든다.

```
Flutter (lib/media/media_platform_bridge.dart)
   │  MethodChannel  "muud_edits/media"           probe / startExport / cancelExport / thumbnail / platformInfo
   │  EventChannel   "muud_edits/export_progress" {event, state, completed_frames, total_frames, message, error}
   ▼
apple/     Swift  AVFoundation + VideoToolbox   (macOS, iOS 공용)
android/   Kotlin MediaMetadataRetriever + Media3 Transformer
windows/   C++    ffmpeg/ffprobe 프로세스 파이프라인
```

## 계약 요약

| 메서드 | 인자 | 응답 |
|---|---|---|
| `probe` | `{path}` | `MediaProbeInfo` 키의 Map (`duration_ms`, `width`, `height`, `fps`, `has_video`, `has_audio`, …) |
| `startExport` | `{graphJson, outputPath}` | 없음. 완료/실패는 이벤트로 |
| `cancelExport` | — | `bool` (요청 접수) |
| `thumbnail` | `{path, atMs, maxWidth}` | `Uint8List`(JPEG) 또는 null |
| `platformInfo` | — | `{api, engine, supports_export, platform, …}` |

이벤트: `event` = `stage` · `progress` · `completed` · `failed` · `canceled`.

진행률·취소의 **정규화는 Rust 코어**(`progress.rs`)가 한다. 네이티브는 원시 값만 보낸다.
Dart는 이벤트를 `export_job_event`에 넣어 `ExportProgress`(퍼센트/ETA/상태 라벨)로 바꾼다.

## 플랫폼별 구현 범위 (v1)

| | macOS / iOS | Android | Windows |
|---|---|---|---|
| 프로브 | AVAsset (`load(.duration)` 등 async API) | MediaMetadataRetriever | ffprobe JSON |
| 썸네일 | AVAssetImageGenerator → JPEG | getScaledFrameAtTime → JPEG | (v1 생략) |
| 합성 | AVMutableComposition + AVMutableVideoComposition (레이어/불투명도/화면 맞춤) | Media3 Transformer (순차 sequence) | ffmpeg filter_complex (순차 concat) |
| 배속 | `scaleTimeRange` | `SpeedChangeEffect` | `setpts` + `atempo` |
| 페이드/볼륨 | `setOpacityRamp` / `setVolumeRamp` | Media3 오디오 처리 | `fade` / `volume` + `afade` |
| 텍스트·자막 번인 | Core Animation overlay + SRT 없이 직접 | 미지원(경고 후 자막 없이 내보냄) | 그래프 자막 → SRT → `subtitles` 필터 |
| 정지 이미지 | 미지원(v1) | 미지원(v1, 거부) | 미지원(v1) |
| 컨테이너 | MP4 / MOV | MP4 | MP4 / MOV(+ ffmpeg 지원 범위) |
| 취소 | `AVAssetExportSession.cancelExport()` | `Transformer.cancel()` | 프로세스 종료 |
| 진행률 | `session.progress` 폴링(0.2s) | `Transformer.getProgress` 폴링 | `-progress pipe:1`의 `frame=` 파싱 |

### 알려진 한계

* **다중 비디오 레이어**: Apple은 `AVMutableVideoComposition` 지시문으로 합성하지만,
  Android/Windows v1은 가장 아래 레이어만 렌더한다(그래프 `layer` 기준).
* **정지 이미지 클립**: 코어 모델에는 있으나 네이티브 v1은 거부한다.
* **Android 텍스트/자막**: 번인 미지원. 그래프에 자막이 있으면 경고 이벤트를 보내고
  자막 없이 내보낸다(무음 손실이 아니라 화면 텍스트 손실).
* **Windows 썸네일**: v1은 null. 필요하면 `ffmpeg -ss … -frames:v 1`로 추가한다.
* 실제 기기/툴체인 빌드 검증은 아직이다(`docs/LOCAL_SETUP.md` 3절).

## 연결

플랫폼 폴더를 `flutter create`로 만든 뒤 파일을 복사/등록하는 절차는
[`docs/LOCAL_SETUP.md`](../../docs/LOCAL_SETUP.md) 3절에 있다.
네이티브를 붙이지 않아도 앱은 실행되고, 미디어 추가는 수동 입력, 내보내기는
"엔진 미연결" 안내로 폴백한다.
