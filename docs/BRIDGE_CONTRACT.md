# Dart ↔ Rust 브리지 계약

이 문서는 `rust_core/src/bridge.rs`와 `app/lib/` 사이의 **실제 계약**이다.
브리지를 고칠 때는 이 문서와 `app/lib/src/rust/api.dart`(생성 전 스텁)를 함께 고친다.

## 1. 원칙

1. **모든 호출은 JSON 문자열 in / JSON 문자열 out.** Dart가 `Map`을 만들어 `jsonEncode`한다.
2. **상태는 Dart가 소유**한다. Rust는 인자로 받은 `state`만 읽고, 새 `state`를 돌려준다.
   Rust 쪽에 세션/전역 상태가 없다(핫 리로드·다중 창·병렬 테스트 안전).
3. **id는 코어가 발급**한다. UI는 `clp-0007` 같은 id를 만들지 않는다.
   필요하면 `created_id`로 받는다.
4. 실패는 예외가 아니라 `{ok:false}` 응답이다. Dart는 `BridgeException(code, message)`로 바꾼다.
5. 워터마크 관련 설정은 **항상 거부**된다(`watermark_not_allowed`).

## 2. 응답 봉투(envelope)

성공:

```json
{
  "ok": true,
  "state": { "project": { "…": "…" }, "history": { "…": "…" }, "dirty": true, "file_path": null },
  "summary": { "id": "prj-…", "name": "새 프로젝트", "duration_ms": 18000, "can_undo": true, "…": "…" },
  "outcome": { "action": "apply", "label": "add_clip", "duration_ms": 18000, "clip_count": 2, "…": "…" },
  "created_id": "clp-0005"
}
```

* `outcome`는 편집 호출에만, `created_id`는 id를 발급하는 호출에만 온다.
* `summary`는 UI 헤더/툴바용 요약이다(프로젝트 전체를 다시 계산하지 않게).

실패:

```json
{ "ok": false, "error": { "code": "overlap", "message": "trk-0001 트랙에서 clp-0003 클립과 겹칩니다" } }
```

### 오류 코드

| code | 의미 | UI 처리 예 |
|---|---|---|
| `track_not_found` / `clip_not_found` | id가 사라짐 | 목록 새로고침 |
| `track_locked` | 잠긴 트랙 편집 | "잠금 해제" 안내 |
| `incompatible_track_kind` | 트랙 종류 불일치(오디오 클립을 비디오 트랙에) | 드롭 거부 |
| `overlap` | 같은 트랙 클립 겹침 | 자석 스냅으로 재시도 |
| `invalid_time_range` / `negative_time` | 시작 ≥ 끝, 음수 | 입력 검증 |
| `split_out_of_range` | 클립 밖에서 분할 | 무시 |
| `empty_text` | 빈 텍스트/자막 | 입력 검증 |
| `watermark_not_allowed` | 워터마크 요청 | 정책상 불가 안내 |
| `invalid_range` | 내보내기 구간이 타임라인 밖 | 구간 다시 지정 |
| `bad_probe` / `invalid_probe` | 프로브 JSON 해석/검증 실패 | 파일 다시 선택 |
| `bad_job` / `bad_event` | 진행률 상태/이벤트 JSON 오류 | 개발자 오류(로그) |
| `odd_dimensions` | H.264/HEVC에 홀수 해상도 | 짝수로 보정 |
| `unsupported_combination` | 컨테이너/코덱 조합 | 다른 조합 제안 |
| `bad_state` / `bad_command` | JSON 해석 실패 | 개발자 오류(로그) |
| `unsupported_schema` | 미래 버전 프로젝트 | 앱 업데이트 안내 |
| `io_error` | 파일 쓰기 실패 | 저장 위치 변경 |

## 3. 함수 목록

| Dart (생성 후) | Rust | 인자 | 용도 |
|---|---|---|---|
| `coreVersion()` | `core_version` | — | 버전 확인 |
| `createProject` | `create_project` | name, width, height, fps | 새 프로젝트 |
| `openProject` | `open_project` | stateJson | 저장 상태 복원 |
| `applyCommand` | `apply_command` | stateJson, commandJson | **일반 편집** |
| `addMediaClip` | `add_media_clip` | state, trackId, kind, sourcePath, start, end, at?, sourceDuration? | 미디어 추가(id 발급) |
| `addTextClip` | `add_text_clip` | state, trackId, content, duration, at, sizePx? | 텍스트 오버레이 |
| `addSubtitle` | `add_subtitle` | state, start?, end?, text | 자막 추가 |
| `splitClip` | `split_clip` | state, trackId, clipId, atTimelineMs | 분할(id 발급) |
| `undo` / `redo` | `undo` / `redo` | state | 되돌리기 / 다시 적용 |
| `projectSummary` | `project_summary` | state | 요약만 |
| `exportPlan` | `export_plan` | state, settingsJson, platformId | 내보내기 계획 |
| `renderGraph` | `render_graph` | state, settingsJson, platformId | **결정적 렌더 그래프**(네이티브 입력) |
| `probeMediaInfo` | `probe_media_info` | probeJson | 플랫폼 프로브 결과 정규화·검증 |
| `exportJobCreate` | `export_job_create` | jobId, totalFrames, atMs? | 진행률 상태 생성 |
| `exportJobEvent` | `export_job_event` | jobJson, eventJson | 진행/단계/취소/완료/실패 반영 |
| `exportJobCancel` | `export_job_cancel` | jobJson, atMs? | 취소 요청(편의) |
| `saveProject` | `save_project` | state, path | `.muudproj` 저장 |
| `loadProject` | `load_project` | path | `.muudproj` 열기 |
| `saveSubtitlesSrt` | `save_subtitles_srt` | state, path | SRT 저장 |
| `projectJson` | `project_json` | state | 파일과 동일한 본문 |
| `platformCapabilities` | `platform_capabilities` | platformId | 역량 표 |
| `trackKinds()` | `track_kinds` | — | 새 트랙 UI |

`platformId`: `macos` · `windows` · `android` · `ios` · `linux`

## 4. 커맨드 스키마

`type` 태그를 가진 유니온이다(`rust_core/src/commands.rs`의 `EditCommand`).
모든 커맨드는 되돌릴 수 있고, 실패하면 상태를 바꾸지 않는다.

```jsonc
// 클립 추가 (id는 코어가 발급받아 쓰는 것을 권장: addMediaClip 사용)
{ "type": "add_clip", "track_id": "trk-0001",
  "clip": { "id": "clp-0004", "source_path": "/media/a.mp4", "kind": "video",
            "start_ms": 0, "end_ms": 4000, "timeline_offset_ms": 0,
            "speed": 1.0, "volume": 1.0, "opacity": 1.0 } }

// 자르기(절대값, 생략한 필드는 유지)
{ "type": "trim_clip", "track_id": "trk-0001", "clip_id": "clp-0004",
  "start_ms": 2000, "end_ms": 4000 }

// 이동(다른 트랙으로도)
{ "type": "move_clip", "track_id": "trk-0001", "clip_id": "clp-0004",
  "to_track_id": "trk-0003", "timeline_offset_ms": 1500 }

// 분할
{ "type": "split_clip", "track_id": "trk-0001", "clip_id": "clp-0004", "at_timeline_ms": 1500 }

// 삭제
{ "type": "remove_clip", "track_id": "trk-0001", "clip_id": "clp-0004" }

// 속성
{ "type": "set_clip_speed",   "track_id": "trk-0001", "clip_id": "clp-0004", "speed": 1.5 }
{ "type": "set_clip_volume",  "track_id": "trk-0001", "clip_id": "clp-0004", "volume": 0.6 }
{ "type": "set_clip_opacity", "track_id": "trk-0001", "clip_id": "clp-0004", "opacity": 0.8 }
{ "type": "set_clip_enabled", "track_id": "trk-0001", "clip_id": "clp-0004", "enabled": false }
{ "type": "set_clip_fades",   "track_id": "trk-0001", "clip_id": "clp-0004", "fade_in_ms": 300, "fade_out_ms": 400 }

// 텍스트 교체(텍스트 클립 전용)
{ "type": "set_clip_text", "track_id": "trk-0003", "clip_id": "clp-0009",
  "text": { "content": "새 문구", "size_px": 72.0, "color": "#FFFFFFFF" } }

// 트랙
{ "type": "add_track", "track": { "id": "trk-0005", "name": "Overlay 2", "kind": "overlay", "clips": [] } }
{ "type": "remove_track", "track_id": "trk-0005" }
{ "type": "rename_track", "track_id": "trk-0005", "name": "자막 바" }
{ "type": "set_track_state", "track_id": "trk-0005", "hidden": true, "locked": true }

// 자막
{ "type": "add_subtitle", "item": { "id": "sub-0002", "start_ms": 0, "end_ms": 1500, "text": "안녕" } }
{ "type": "update_subtitle", "id": "sub-0002", "patch": { "text": "안녕하세요" } }
{ "type": "remove_subtitle", "id": "sub-0002" }

// 묶음(원자적, 실패 시 아무것도 남지 않음)
{ "type": "batch", "commands": [ /* … */ ] }
```

### 값 범위

| 필드 | 범위 |
|---|---|
| `speed` | 0.25 ~ 4.0 |
| `volume` | 0.0 ~ 2.0 |
| `opacity` | 0.0 ~ 1.0 |
| 시간 | 0 이상 정수 ms, `start < end` |
| 트랙 겹침 | Video/Audio 트랙 불가, Overlay 트랙 허용 |

## 5. 내보내기 설정(`export_plan`의 `settingsJson`)

빈 문자열이면 프로젝트 기본값을 쓴다.

```json
{
  "resolution": { "width": 1080, "height": 1920 },
  "fps": 30,
  "video_bitrate_kbps": 8000,
  "codec": "h264",
  "container": "mp4",
  "audio_codec": "aac",
  "audio_bitrate_kbps": 192,
  "hardware": "auto",
  "gop_frames": 60,
  "range": { "start_ms": 0, "end_ms": 15000 },
  "burn_in_subtitles": true,
  "watermark": false
}
```

* `codec`: `h264` · `hevc` · `av1` · `vp9` · `prores`
* `container`: `mp4` · `mov` · `webm`
* `audio_codec`: `aac` · `opus` · `pcm_s16le`
* `hardware`: `auto` · `software` · `videotoolbox` · `mediafoundation` · `mediacodec` · `nvenc` · `qsv` · `vaapi`
* `watermark`: **true는 거부**된다. 제품 원칙상 항상 false.
* `burn_in_subtitles`: 자막을 영상에 구울지(기본 true). false면 그래프의 `subtitles.enabled`가 false가 된다.

응답의 `plan`:

```json
{
  "platform": "android",
  "container": "mp4",
  "codec": "h264",
  "encoder": { "name": "h264_mediacodec", "hardware": true, "backend": "mediacodec",
               "notes": "android 하드웨어 인코더 사용 (mediacodec h264)" },
  "resolution": { "width": 1080, "height": 1920 },
  "fps": 30,
  "video_bitrate_kbps": 8087,
  "output_extension": "mp4",
  "ffmpeg_args": ["-hide_banner", "-y", "…"],
  "ffmpeg_command": "ffmpeg -hide_banner -y …",
  "watermark": false,
  "notes": ["…", "워터마크 없음: 활성 (요청 값 watermark=false)", "…"]
}
```

## 6. 렌더 그래프 · 진행률 · 프로브

### 6.1 `render_graph` 응답

```json
{
  "ok": true,
  "graph": {
    "project_id": "prj-…", "project_name": "상하이 브이로그",
    "platform": "android", "container": "mp4",
    "video_codec": "h264", "audio_codec": "aac",
    "encoder": { "name": "h264_mediacodec", "hardware": true, "backend": "mediacodec", "notes": "…" },
    "resolution": { "width": 1080, "height": 1920 }, "fps": 30,
    "gop_frames": 60, "video_bitrate_kbps": 8087, "sample_rate": 48000,
    "duration_ms": 6000, "frame_count": 180,
    "range": null,
    "segments": [ {
      "index": 0, "layer": 0, "track_id": "trk-0001", "clip_id": "clp-0001",
      "kind": "video", "source_path": "/media/a.mp4",
      "source_in_ms": 0, "source_out_ms": 4000,
      "timeline_start_ms": 0, "timeline_end_ms": 4000,
      "render_start_ms": 0, "render_end_ms": 4000,
      "frame_start": 0, "frame_end": 120,
      "speed": 1.0, "opacity": 1.0,
      "opacity_curve": [ {"at_ms": 0, "value": 0.0}, {"at_ms": 500, "value": 1.0}, {"at_ms": 4000, "value": 1.0} ],
      "text": null
    } ],
    "audio_segments": [ {
      "index": 0, "track_id": "trk-0002", "clip_id": "clp-0003",
      "source_path": "/media/bgm.m4a", "source_in_ms": 0, "source_out_ms": 6000,
      "render_start_ms": 0, "render_end_ms": 6000,
      "frame_start": 0, "frame_end": 180,
      "speed": 1.0, "gain": 0.4,
      "gain_curve": [ {"at_ms": 0, "value": 0.0}, {"at_ms": 1000, "value": 0.4}, {"at_ms": 6000, "value": 0.0} ],
      "muted": false, "from_video_track": false, "has_audio_stream": null
    } ],
    "subtitles": { "enabled": true, "style": { "…": "…" }, "items": [ {
      "id": "sub-0001", "start_ms": 500, "end_ms": 2500,
      "render_start_ms": 500, "render_end_ms": 2500,
      "frame_start": 15, "frame_end": 75,
      "style": { "…": "…" }, "display_text": "오늘은 상하이 마라톤\n준비 마지막 주"
    } ] },
    "watermark": false, "notes": [ "…" ],
    "graph_digest": "9f2c1a4b7d3e5c60"
  },
  "plan": { "…": "ExportPlan과 동일" },
  "summary": "mp4 1080x1920@30 · 180 frames/6000ms · 영상 2 · 오디오 1 · 자막 1 · 9f2c1a4b7d3e5c60"
}
```

* `layer`: 작을수록 아래. `opacity_curve`/`gain_curve`는 세그먼트 시작 기준 로컬 ms.
* `render_*`는 내보내기 구간이 있으면 당겨진 시각, `timeline_*`는 프로젝트 절대 시각이다.
* 같은 입력이면 `graph_digest`가 항상 같다(캐시 키/회귀 비교에 쓴다).

### 6.2 `probe_media_info` 요청/응답

요청은 플랫폼이 돌려준 Map을 그대로 JSON으로 만든 것이다.

```json
{ "path": "/media/a.mp4", "duration_ms": 12500, "width": 1080, "height": 1920,
  "fps": 29.97, "has_video": true, "has_audio": true,
  "audio_channels": 2, "audio_sample_rate": 48000,
  "video_codec": "h264", "audio_codec": "aac", "rotation_degrees": 0,
  "source": "android-media" }
```

응답:

```json
{ "ok": true, "probe": { "…": "정규화된 MediaProbeInfo" },
  "media_type": "video", "clip_kind": "video", "suggested_end_ms": 12500,
  "summary": "video · 1080x1920 · 29.97fps · 00:00:12.500 · 오디오 있음",
  "warnings": [] }
```

* `clip_kind`: `video` · `audio` · `image` · `null`. null이면 클립을 만들지 않는다.
* 스트림이 없고 해상도만 있으면 `image`로 판정하고 `suggested_end_ms`는 null이다.
* `duration_ms`가 0인 비디오, 해상도 0, 90도 단위가 아닌 회전은 `invalid_probe`.

### 6.3 `export_job_*` — 진행률/취소

`export_job_create` 응답:

```json
{ "ok": true, "job": { "job_id": "job-1764…", "progress": {
    "state": "queued", "state_label": "대기 중",
    "completed_frames": 0, "total_frames": 240,
    "fraction": 0.0, "percent": 0.0,
    "started_at_ms": 1764…, "updated_at_ms": 1764…, "elapsed_ms": 0,
    "eta_ms": null, "cancel_requested": false, "message": null, "error": null } },
  "summary": "대기 중 · 0.0% (0/240 frames) · job-1764…" }
```

`export_job_event(jobJson, eventJson)` — 이벤트 종류:

| event JSON | 효과 |
|---|---|
| `{"type":"stage","state":"preparing"}` | 단계 전환(뒤로 가는 전환은 무시) |
| `{"type":"progress","completed_frames":120}` | 진행률 갱신, 필요하면 자동 `rendering` |
| `{"type":"cancel_request"}` | 취소 요청(시작 전이면 즉시 `canceled`) |
| `{"type":"canceled"}` | 네이티브 확정 → `canceled` |
| `{"type":"completed"}` | `completed`(100%) |
| `{"type":"failed","message":"…"}` | `failed` + 오류 메시지 |

응답은 `{ok, applied, job, summary}`. 종료 상태 뒤 이벤트는 `applied:false`로 무시된다.
각 이벤트에 `at_ms`를 넣으면 시간 계산이 재현된다(테스트/로그용).

## 7. 상태(State)의 모양

`state`는 `rust_core::Editor`의 직렬화다.

```json
{
  "project": {
    "schema_version": 1, "id": "prj-1764…", "name": "새 프로젝트",
    "resolution": { "width": 1080, "height": 1920 }, "fps": 30, "sample_rate": 48000,
    "tracks": [ { "id": "trk-0001", "name": "Video 1", "kind": "video", "clips": [ … ],
                  "muted": false, "hidden": false, "locked": false, "gain": 1.0 } ],
    "subtitles": { "enabled": true, "style": { … }, "items": [ … ] },
    "export": { … }, "ids": { "next": 9 }
  },
  "history": { "undo_stack": [ … ], "redo_stack": [], "limit": 200 },
  "dirty": true,
  "file_path": null
}
```

* `history`도 직렬화되므로 프로젝트를 저장하면 **되돌리기 기록도 함께** 남는다.
* Dart는 `project.tracks[].clips[]`를 파싱해 타임라인을 그린다(`lib/models.dart`).
* 파일(`.muudproj`)은 `project` 부분만 저장한다(히스토리는 세션 상태).

## 8. 코드 생성 후 체크리스트

1. `lib/src/rust/api.dart`가 생성 파일로 바뀌었는지 확인(스텁 헤더가 사라진다).
2. `lib/core_bridge.dart`의 호출 인자 이름이 생성 시그니처와 맞는지 확인
   (FRB는 snake_case → camelCase, `&str` → `String`, `Option<T>` → `T?`로 만든다).
3. `main()`에 `await RustLib.init();` 추가.
4. `flutter run` 후 헤더에 "코어 v0.1.0 연결됨"이 뜨면 성공.
