//! flutter_rust_bridge 표면.
//!
//! ## 왜 JSON 문자열인가
//! flutter_rust_bridge는 Rust 타입을 Dart 클래스로 생성해 준다. 그런데 편집
//! 커맨드는 20여 종의 태그드 유니온이고, 프로젝트 모델은 계속 늘어난다.
//! 초기 버전에서는 **경계를 얇게** 유지하는 편이 훨씬 빠르게 움직일 수 있다:
//!
//! * Dart는 `Map<String, dynamic>`을 만들어 `jsonEncode`해서 넘긴다.
//! * Rust는 [`EditCommand`]로 역직렬화해 적용하고, 결과 상태를 통째로 돌려준다.
//! * 나중에 타입 안전한 API로 승격할 때도 이 함수 시그니처는 그대로 두고
//!   내부만 바꾸면 된다.
//!
//! ## 상태 관리
//! 편집기 상태(프로젝트 + 히스토리)는 **Dart가 소유**한다. 각 호출은
//! `state`를 받아 새 상태를 돌려주며, Rust 쪽에는 아무 상태도 남기지 않는다.
//! 이 방식은 핫 리로드, 다중 창, 테스트에 모두 유리하다.
//!
//! 반환값은 항상 다음 형태의 JSON 문자열이다.
//! ```json
//! { "ok": true, "state": {...}, "summary": {...}, "outcome": {...} }
//! { "ok": false, "error": { "code": "overlap", "message": "..." } }
//! ```

use serde_json::{json, Value};

use crate::commands::{CommandOutcome, EditCommand};
use crate::editor::Editor;
use crate::error::{EditError, ExportError, ProjectIoError};
use crate::export::ExportSettings;
use crate::ids::{ClipId, TrackId};
use crate::model::{ClipKind, Project, Resolution, TextOverlay};
use crate::platform::Platform;
use crate::probe::MediaProbeInfo;
use crate::progress::{ExportJob, ExportJobEvent};
use crate::project_io;
use crate::render_plan::RenderGraph;

/// 코어 엔진 버전.
pub fn core_version() -> String {
    crate::CORE_VERSION.to_string()
}

/// 새 프로젝트를 만든다. Video/Audio/Overlay 트랙이 기본으로 들어간다.
pub fn create_project(name: &str, width: u32, height: u32, fps: u32) -> Result<String, String> {
    if name.trim().is_empty() {
        return Err(error_json("invalid", "프로젝트 이름이 비어 있습니다", None));
    }
    if width < 2 || height < 2 {
        return Err(error_json("invalid", "해상도가 올바르지 않습니다", None));
    }
    let editor = Editor::blank(
        name.trim(),
        Resolution::new(width, height),
        fps.clamp(1, 120),
    );
    Ok(envelope(&editor, None))
}

/// 저장된 상태(또는 프로젝트 JSON)를 편집기 상태로 연다.
pub fn open_project(state_json: &str) -> Result<String, String> {
    let editor = parse_editor(state_json)?;
    Ok(envelope(&editor, None))
}

/// 편집 커맨드 하나를 적용한다.
///
/// `command_json` 예:
/// `{"type":"add_clip","track_id":"trk-0001","clip":{"id":"clp-0004","source_path":"/v/a.mp4","kind":"video","start_ms":0,"end_ms":2000,"timeline_offset_ms":0}}`
pub fn apply_command(state_json: &str, command_json: &str) -> Result<String, String> {
    let mut editor = parse_editor(state_json)?;
    let command: EditCommand = serde_json::from_str(command_json).map_err(|e| {
        error_json(
            "bad_command",
            &format!("커맨드 JSON을 해석하지 못했습니다: {e}"),
            None,
        )
    })?;
    let outcome = editor.apply(command).map_err(edit_error_json)?;
    Ok(envelope(&editor, Some(outcome)))
}

/// 미디어 클립 추가(UI는 id를 만들지 않는다 — 코어가 발급한다).
///
/// `at_ms`가 없으면 트랙 끝에 이어 붙인다. `created_id`에 새 클립 id가 온다.
pub fn add_media_clip(
    state_json: &str,
    track_id: &str,
    kind: &str,
    source_path: &str,
    start_ms: i64,
    end_ms: i64,
    at_ms: Option<i64>,
    source_duration_ms: Option<i64>,
) -> Result<String, String> {
    let mut editor = parse_editor(state_json)?;
    let track = TrackId::new(track_id);
    let clip_kind = match kind {
        "video" => ClipKind::Video,
        "audio" => ClipKind::Audio,
        "image" => ClipKind::Image,
        "text" => {
            return Err(error_json(
                "bad_kind",
                "텍스트 클립은 add_text_clip을 사용하세요",
                None,
            ))
        }
        other => {
            return Err(error_json(
                "bad_kind",
                &format!("알 수 없는 클립 종류입니다: {other}"),
                None,
            ))
        }
    };

    let created = match source_duration_ms {
        Some(duration) => {
            editor.add_media_clip_with_duration(&track, clip_kind, source_path, duration, at_ms)
        }
        None => editor.add_media_clip(&track, clip_kind, source_path, start_ms, end_ms, at_ms),
    }
    .map_err(edit_error_json)?;

    Ok(envelope_with_created(&editor, &created.to_string()))
}

/// 텍스트 오버레이 클립 추가.
pub fn add_text_clip(
    state_json: &str,
    track_id: &str,
    content: &str,
    duration_ms: i64,
    at_ms: i64,
    size_px: Option<f64>,
) -> Result<String, String> {
    let mut editor = parse_editor(state_json)?;
    let mut text = TextOverlay::new(content);
    if let Some(size) = size_px {
        text.size_px = size as f32;
    }
    let created = editor
        .add_text_clip(&TrackId::new(track_id), text, duration_ms, at_ms)
        .map_err(edit_error_json)?;
    Ok(envelope_with_created(&editor, &created.to_string()))
}

/// 자막 추가(시간을 생략하면 마지막 자막 뒤에 붙는다).
pub fn add_subtitle(
    state_json: &str,
    start_ms: Option<i64>,
    end_ms: Option<i64>,
    text: &str,
) -> Result<String, String> {
    let mut editor = parse_editor(state_json)?;
    let created = editor
        .add_subtitle(start_ms, end_ms, text)
        .map_err(edit_error_json)?;
    Ok(envelope_with_created(&editor, &created.to_string()))
}

/// 타임라인 위치에서 클립 분할. `created_id`는 오른쪽 조각의 id.
pub fn split_clip(
    state_json: &str,
    track_id: &str,
    clip_id: &str,
    at_timeline_ms: i64,
) -> Result<String, String> {
    let mut editor = parse_editor(state_json)?;
    let created = editor
        .split(
            &TrackId::new(track_id),
            &ClipId::new(clip_id),
            at_timeline_ms,
        )
        .map_err(edit_error_json)?;
    Ok(envelope_with_created(&editor, &created.to_string()))
}

/// 되돌리기.
pub fn undo(state_json: &str) -> Result<String, String> {
    let mut editor = parse_editor(state_json)?;
    let outcome = editor.undo().map_err(edit_error_json)?;
    Ok(envelope(&editor, outcome))
}

/// 다시 적용.
pub fn redo(state_json: &str) -> Result<String, String> {
    let mut editor = parse_editor(state_json)?;
    let outcome = editor.redo().map_err(edit_error_json)?;
    Ok(envelope(&editor, outcome))
}

/// UI 요약만 돌려준다(상태는 그대로).
pub fn project_summary(state_json: &str) -> Result<String, String> {
    let editor = parse_editor(state_json)?;
    Ok(json!({
        "ok": true,
        "summary": editor.summary(),
    })
    .to_string())
}

/// 내보내기 계획(설정 검증 + 인코더 선택 + ffmpeg 인자).
///
/// `settings_json`이 비어 있으면 프로젝트의 기본 설정을 쓴다.
pub fn export_plan(
    state_json: &str,
    settings_json: &str,
    platform_id: &str,
) -> Result<String, String> {
    let editor = parse_editor(state_json)?;
    let platform = parse_platform(platform_id)?;

    let settings = parse_settings(&editor, settings_json)?;

    settings.validate_for(platform).map_err(export_error_json)?;

    let plan = settings.plan(
        platform,
        "<input>",
        &format!("<output>.{}", settings.container.extension()),
    );
    Ok(json!({
        "ok": true,
        "plan": plan,
        "summary": editor.summary(),
    })
    .to_string())
}

/// 타임라인을 결정적 렌더 그래프로 컴파일한다.
///
/// 4개 플랫폼 네이티브 엔진이 이 결과를 그대로 소비한다.
/// `settings_json`이 비어 있으면 프로젝트의 기본 설정을 쓴다.
pub fn render_graph(
    state_json: &str,
    settings_json: &str,
    platform_id: &str,
) -> Result<String, String> {
    let editor = parse_editor(state_json)?;
    let platform = parse_platform(platform_id)?;
    let settings = parse_settings(&editor, settings_json)?;

    let graph =
        RenderGraph::compile(&editor.project, &settings, platform).map_err(export_error_json)?;
    let plan = settings.plan(
        platform,
        "<input>",
        &format!("<output>.{}", settings.container.extension()),
    );
    Ok(json!({
        "ok": true,
        "graph": graph,
        "plan": plan,
        "summary": graph.summary(),
    })
    .to_string())
}

/// 플랫폼 네이티브 프로브 결과를 검증/정규화한다.
///
/// 성공하면 `probe`(정규화된 [`MediaProbeInfo`]), `media_type`, `clip_kind`,
/// `suggested_end_ms`, `summary`, `warnings`를 돌려준다. 실패는 `bad_probe`/
/// `invalid_probe` 코드의 구조화된 오류다.
pub fn probe_media_info(probe_json: &str) -> Result<String, String> {
    let info = MediaProbeInfo::from_json(probe_json)
        .map_err(|message| error_json("bad_probe", &message, None))?;
    info.validate()
        .map_err(|message| error_json("invalid_probe", &message, None))?;
    Ok(json!({
        "ok": true,
        "probe": info,
        "media_type": info.media_type().as_str(),
        "clip_kind": info.clip_kind().map(|kind| kind.as_str()),
        "suggested_end_ms": info.suggested_end_ms(),
        "summary": info.summary(),
        "warnings": info.warnings(),
    })
    .to_string())
}

/// 내보내기 작업 상태를 만든다(코어는 상태를 저장하지 않는다).
///
/// `at_ms`가 없으면 현재 시각을 쓴다. 반환된 `job`을 이후
/// [`export_job_event`]에 그대로넘긴다.
pub fn export_job_create(job_id: &str, total_frames: i64, at_ms: Option<i64>) -> String {
    let now = at_ms.unwrap_or_else(crate::now_ms);
    let job = ExportJob::new(job_id, total_frames.max(0) as u64, now);
    json!({
        "ok": true,
        "job": job,
        "summary": job.summary(),
    })
    .to_string()
}

/// 내보내기 진행률/단계/취소 이벤트를 적용한다.
///
/// `event_json` 예:
/// `{"type":"stage","state":"rendering"}`,
/// `{"type":"progress","completed_frames":120}`,
/// `{"type":"cancel_request"}`, `{"type":"canceled"}`,
/// `{"type":"completed"}`, `{"type":"failed","message":"..."}`
///
/// 종료 상태(completed/canceled/failed) 뒤의 이벤트는 `applied: false`로 무시된다.
pub fn export_job_event(job_json: &str, event_json: &str) -> Result<String, String> {
    let mut job: ExportJob = serde_json::from_str(job_json).map_err(|err| {
        error_json(
            "bad_job",
            &format!("내보내기 작업 JSON을 해석하지 못했습니다: {err}"),
            None,
        )
    })?;
    let event: ExportJobEvent = serde_json::from_str(event_json).map_err(|err| {
        error_json(
            "bad_event",
            &format!("내보내기 이벤트 JSON을 해석하지 못했습니다: {err}"),
            None,
        )
    })?;
    let applied = job.apply(&event, crate::now_ms());
    Ok(json!({
        "ok": true,
        "applied": applied,
        "job": job,
        "summary": job.summary(),
    })
    .to_string())
}

/// 사용자 취소 요청(편의 함수). [`ExportJobEvent::CancelRequest`]와 같다.
pub fn export_job_cancel(job_json: &str, at_ms: Option<i64>) -> Result<String, String> {
    let event = ExportJobEvent::CancelRequest { at_ms };
    export_job_event(job_json, &serde_json::to_string(&event).unwrap_or_default())
}

/// 프로젝트를 파일로 저장한다(`.muudproj`).
pub fn save_project(state_json: &str, path: &str) -> Result<String, String> {
    let mut editor = parse_editor(state_json)?;
    editor.save_to(path).map_err(io_error_json)?;
    Ok(envelope(&editor, None))
}

/// 프로젝트 파일을 연다.
pub fn load_project(path: &str) -> Result<String, String> {
    let editor = Editor::load_from(path).map_err(io_error_json)?;
    Ok(envelope(&editor, None))
}

/// 자막을 SRT로 저장한다. 자막이 없으면 `written: null`.
pub fn save_subtitles_srt(state_json: &str, path: &str) -> Result<String, String> {
    let editor = parse_editor(state_json)?;
    let written = editor.save_srt(path).map_err(io_error_json)?;
    Ok(json!({ "ok": true, "written": written }).to_string())
}

/// 프로젝트 본문(저장 파일과 같은 JSON)만 돌려준다.
pub fn project_json(state_json: &str) -> Result<String, String> {
    let editor = parse_editor(state_json)?;
    project_io::to_json(&editor.project).map_err(io_error_json)
}

/// 플랫폼 미디어 역량 표(설정 화면 표시용).
pub fn platform_capabilities(platform_id: &str) -> Result<String, String> {
    let platform = Platform::from_id(platform_id).ok_or_else(|| {
        error_json(
            "bad_platform",
            &format!("알 수 없는 플랫폼입니다: {platform_id}"),
            None,
        )
    })?;
    Ok(json!({
        "ok": true,
        "platform": platform.id(),
        "capabilities": platform.capabilities(),
    })
    .to_string())
}

/// 편집 가능한 트랙 종류 목록(새 트랙 추가 UI).
pub fn track_kinds() -> String {
    json!({
        "ok": true,
        "kinds": [
            { "id": "video", "label": "비디오" },
            { "id": "audio", "label": "오디오" },
            { "id": "overlay", "label": "오버레이" }
        ]
    })
    .to_string()
}

// ------------------------------------------------------------------ internals

/// 상태 JSON을 편집기로 되살린다. 프로젝트 JSON도 받아 준다.
fn parse_editor(state_json: &str) -> Result<Editor, String> {
    if let Ok(editor) = serde_json::from_str::<Editor>(state_json) {
        return Ok(editor);
    }
    match serde_json::from_str::<Project>(state_json) {
        Ok(project) => Ok(Editor::new(project)),
        Err(err) => Err(error_json(
            "bad_state",
            &format!("편집기 상태를 해석하지 못했습니다: {err}"),
            None,
        )),
    }
}

fn envelope(editor: &Editor, outcome: Option<CommandOutcome>) -> String {
    let mut value = json!({
        "ok": true,
        "state": editor,
        "summary": editor.summary(),
    });
    if let Some(outcome) = outcome {
        // 새 클립을 만든 커맨드(extract_audio/duplicate_clip)는 UI 가 결과 클립을
        // 바로 선택할 수 있도록 `created_id` 를 최상위에도 같이 둔다.
        if let Some(created) = outcome.created_clip_id.clone() {
            value["created_id"] = json!(created);
        }
        value["outcome"] = serde_json::to_value(outcome).unwrap_or(Value::Null);
    }
    value.to_string()
}

fn envelope_with_created(editor: &Editor, created_id: &str) -> String {
    json!({
        "ok": true,
        "state": editor,
        "summary": editor.summary(),
        "created_id": created_id,
    })
    .to_string()
}

/// 플랫폼 문자열 → [`Platform`]. 모르는 값은 구조화된 오류.
fn parse_platform(platform_id: &str) -> Result<Platform, String> {
    Platform::from_id(platform_id).ok_or_else(|| {
        error_json(
            "bad_platform",
            &format!("알 수 없는 플랫폼입니다: {platform_id}"),
            None,
        )
    })
}

/// 내보내기 설정 JSON. 비어 있으면 프로젝트 기본값.
fn parse_settings(editor: &Editor, settings_json: &str) -> Result<ExportSettings, String> {
    if settings_json.trim().is_empty() {
        return Ok(editor.project.export.clone());
    }
    serde_json::from_str(settings_json).map_err(|err| {
        error_json(
            "bad_settings",
            &format!("내보내기 설정 JSON을 해석하지 못했습니다: {err}"),
            None,
        )
    })
}

fn error_json(code: &str, message: &str, extra: Option<Value>) -> String {
    let mut value = json!({
        "ok": false,
        "error": { "code": code, "message": message },
    });
    if let Some(extra) = extra {
        value["error"]["details"] = extra;
    }
    value.to_string()
}

fn edit_error_json(err: EditError) -> String {
    error_json(err.code(), &err.to_string(), None)
}

fn export_error_json(err: ExportError) -> String {
    let code = match &err {
        ExportError::WatermarkNotAllowed => "watermark_not_allowed",
        ExportError::InvalidResolution { .. } => "invalid_resolution",
        ExportError::OddDimensions { .. } => "odd_dimensions",
        ExportError::InvalidFrameRate { .. } => "invalid_frame_rate",
        ExportError::InvalidBitrate { .. } => "invalid_bitrate",
        ExportError::UnsupportedCombination { .. } => "unsupported_combination",
        ExportError::InvalidRange { .. } => "invalid_range",
    };
    error_json(code, &err.to_string(), None)
}

fn io_error_json(err: ProjectIoError) -> String {
    let code = match &err {
        ProjectIoError::Io(_) => "io_error",
        ProjectIoError::Json(_) => "bad_project_json",
        ProjectIoError::UnsupportedSchema { .. } => "unsupported_schema",
    };
    error_json(code, &err.to_string(), None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Clip;

    fn state_from(result: Result<String, String>) -> Value {
        let text = result.expect("bridge call");
        serde_json::from_str(&text).expect("json")
    }

    #[test]
    fn create_project_returns_state_and_summary() {
        let value = state_from(create_project("브리지", 1080, 1920, 30));
        assert_eq!(value["ok"], true);
        assert_eq!(value["summary"]["track_count"], 3);
        assert_eq!(value["summary"]["duration_ms"], 0);
        assert!(value["state"]["project"]["id"].is_string());
    }

    #[test]
    fn command_roundtrip_through_json_strings() {
        let created = state_from(create_project("브리지", 1080, 1920, 30));
        let state = created["state"].to_string();
        let track_id = created["state"]["project"]["tracks"][0]["id"]
            .as_str()
            .expect("track id")
            .to_string();

        let clip = Clip::new_media(
            crate::ids::ClipId::new("clp-9001"),
            crate::model::ClipKind::Video,
            "/media/a.mp4",
            0,
            2_500,
        );
        let command = json!({
            "type": "add_clip",
            "track_id": track_id,
            "clip": clip,
        })
        .to_string();

        let applied = state_from(apply_command(&state, &command));
        assert_eq!(applied["ok"], true);
        assert_eq!(applied["summary"]["clip_count"], 1);
        assert_eq!(applied["summary"]["duration_ms"], 2_500);
        assert_eq!(applied["outcome"]["action"], "apply");

        let with_clip = applied["state"].to_string();
        let undone = state_from(undo(&with_clip));
        assert_eq!(undone["summary"]["clip_count"], 0);
        assert_eq!(undone["outcome"]["action"], "undo");
    }

    #[test]
    fn invalid_command_returns_structured_error() {
        let created = state_from(create_project("브리지", 1080, 1920, 30));
        let state = created["state"].to_string();
        let err = apply_command(&state, "{\"type\":\"nope\"}").unwrap_err();
        let value: Value = serde_json::from_str(&err).expect("json");
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "bad_command");
    }

    #[test]
    fn overlap_error_is_reported_with_code() {
        let created = state_from(create_project("브리지", 1080, 1920, 30));
        let state = created["state"].to_string();
        let track_id = created["state"]["project"]["tracks"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();

        let mut first = Clip::new_media(
            crate::ids::ClipId::new("clp-1"),
            crate::model::ClipKind::Video,
            "/a.mp4",
            0,
            2_000,
        );
        first.timeline_offset_ms = 0;
        let mut second = Clip::new_media(
            crate::ids::ClipId::new("clp-2"),
            crate::model::ClipKind::Video,
            "/b.mp4",
            0,
            2_000,
        );
        second.timeline_offset_ms = 1_000;

        let cmd1 = json!({"type":"add_clip","track_id":track_id,"clip":first}).to_string();
        let after_first = state_from(apply_command(&state, &cmd1));
        let state2 = after_first["state"].to_string();

        let cmd2 = json!({"type":"add_clip","track_id":track_id,"clip":second}).to_string();
        let err = apply_command(&state2, &cmd2).unwrap_err();
        let value: Value = serde_json::from_str(&err).expect("json");
        assert_eq!(value["error"]["code"], "overlap");
    }

    #[test]
    fn export_plan_for_android_is_hardware() {
        let created = state_from(create_project("브리지", 1080, 1920, 30));
        let state = created["state"].to_string();
        let value = state_from(export_plan(&state, "", "android"));
        assert_eq!(value["plan"]["encoder"]["name"], "h264_mediacodec");
        assert_eq!(value["plan"]["watermark"], false);
        assert_eq!(value["plan"]["output_extension"], "mp4");
    }

    #[test]
    fn watermark_option_is_refused() {
        let created = state_from(create_project("브리지", 1080, 1920, 30));
        let state = created["state"].to_string();
        let settings = json!({ "watermark": true }).to_string();
        let err = export_plan(&state, &settings, "macos").unwrap_err();
        let value: Value = serde_json::from_str(&err).expect("json");
        assert_eq!(value["error"]["code"], "watermark_not_allowed");
    }

    #[test]
    fn platform_capabilities_lists_encoders() {
        let value = state_from(platform_capabilities("ios"));
        assert_eq!(value["capabilities"]["platform"], "ios");
        assert!(value["capabilities"]["hw_encode"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c == "hevc"));
    }

    #[test]
    fn project_json_is_a_file_payload() {
        let created = state_from(create_project("브리지", 1080, 1920, 30));
        let state = created["state"].to_string();
        let text = project_json(&state).expect("project json");
        let value: Value = serde_json::from_str(&text).expect("json");
        assert_eq!(value["schema_version"], crate::project_io::SCHEMA_VERSION);
        assert_eq!(value["tracks"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn convenience_calls_mint_ids_and_keep_state() {
        let created = state_from(create_project("브리지", 1080, 1920, 30));
        let state = created["state"].to_string();
        let track_id = created["state"]["project"]["tracks"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();

        let added = state_from(add_media_clip(
            &state,
            &track_id,
            "video",
            "/media/a.mp4",
            0,
            4_000,
            None,
            Some(4_000),
        ));
        let clip_id = added["created_id"]
            .as_str()
            .expect("created id")
            .to_string();
        assert!(
            clip_id.starts_with("clp-"),
            "코어가 id를 발급한다: {clip_id}"
        );
        assert_eq!(added["summary"]["duration_ms"], 4_000);

        let split_state = added["state"].to_string();
        let split = state_from(split_clip(&split_state, &track_id, &clip_id, 1_500));
        assert_eq!(split["summary"]["clip_count"], 2);
        assert!(split["created_id"].as_str().unwrap().starts_with("clp-"));

        let sub_state = split["state"].to_string();
        let sub = state_from(add_subtitle(&sub_state, None, None, "첫 자막"));
        assert_eq!(sub["summary"]["subtitle_count"], 1);
        assert!(sub["created_id"].as_str().unwrap().starts_with("sub-"));

        let bad =
            add_media_clip(&state, &track_id, "text", "/x", 0, 1_000, None, None).unwrap_err();
        let value: Value = serde_json::from_str(&bad).expect("json");
        assert_eq!(value["error"]["code"], "bad_kind");
    }

    #[test]
    fn extract_audio_bridge_returns_created_clip_and_mixes_it() {
        let created = state_from(create_project("오디오 추출", 1080, 1920, 30));
        let state = created["state"].to_string();
        let video_track = created["state"]["project"]["tracks"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();
        let added = state_from(add_media_clip(
            &state,
            &video_track,
            "video",
            "/media/a.mp4",
            0,
            4_000,
            None,
            Some(4_000),
        ));
        let clip_id = added["created_id"].as_str().unwrap().to_string();
        let with_clip = added["state"].to_string();

        let command = json!({
            "type": "extract_audio",
            "track_id": video_track,
            "clip_id": clip_id,
        })
        .to_string();
        let extracted = state_from(apply_command(&with_clip, &command));
        assert_eq!(extracted["ok"], true);
        assert_eq!(extracted["outcome"]["label"], "extract_audio");
        let audio_id = extracted["created_id"]
            .as_str()
            .expect("오디오 클립 id")
            .to_string();
        assert!(audio_id.starts_with("clp-"));
        assert_eq!(extracted["outcome"]["created_clip_id"], audio_id.as_str());

        let tracks = extracted["state"]["project"]["tracks"].as_array().unwrap();
        assert_eq!(tracks[1]["clips"].as_array().unwrap().len(), 1);
        assert_eq!(tracks[1]["clips"][0]["kind"], "audio");
        assert_eq!(tracks[0]["clips"][0]["volume"], 0.0);

        // 렌더 그래프에도 오디오가 한 번만 들어간다(원본은 무음).
        let graph_state = extracted["state"].to_string();
        let graph = state_from(render_graph(&graph_state, "", "android"));
        let audio_segments = graph["graph"]["audio_segments"].as_array().unwrap();
        assert_eq!(audio_segments.len(), 1);
        assert_eq!(audio_segments[0]["from_video_track"], false);
        assert_eq!(audio_segments[0]["source_path"], "/media/a.mp4");
    }

    #[test]
    fn duplicate_and_rename_through_bridge_keep_single_step_undo() {
        let created = state_from(create_project("이름", 1080, 1920, 30));
        let mut state = created["state"].to_string();
        let track_id = created["state"]["project"]["tracks"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();
        let added = state_from(add_media_clip(
            &state,
            &track_id,
            "video",
            "/media/a.mp4",
            0,
            1_000,
            None,
            Some(1_000),
        ));
        let clip_id = added["created_id"].as_str().unwrap().to_string();
        state = added["state"].to_string();

        let renamed = state_from(apply_command(
            &state,
            &json!({ "type": "rename_project", "name": "상하이 마라톤" }).to_string(),
        ));
        assert_eq!(renamed["summary"]["name"], "상하이 마라톤");
        state = renamed["state"].to_string();

        let duplicated = state_from(apply_command(
            &state,
            &json!({"type": "duplicate_clip", "track_id": track_id, "clip_id": clip_id})
                .to_string(),
        ));
        assert_eq!(duplicated["summary"]["clip_count"], 2);
        assert!(duplicated["created_id"]
            .as_str()
            .unwrap()
            .starts_with("clp-"));

        let undone = state_from(undo(&duplicated["state"].to_string()));
        assert_eq!(undone["summary"]["clip_count"], 1);
        let undone = state_from(undo(&undone["state"].to_string()));
        assert_eq!(undone["summary"]["name"], "이름");
    }

    #[test]
    fn render_graph_bridge_returns_segments_and_digest() {
        let created = state_from(create_project("그래프", 1080, 1920, 30));
        let state = created["state"].to_string();
        let track_id = created["state"]["project"]["tracks"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();
        let added = state_from(add_media_clip(
            &state,
            &track_id,
            "video",
            "/media/a.mp4",
            0,
            4_000,
            None,
            Some(4_000),
        ));
        let with_clip = added["state"].to_string();

        let value = state_from(render_graph(&with_clip, "", "android"));
        assert_eq!(value["ok"], true);
        assert_eq!(value["graph"]["frame_count"], 120);
        assert_eq!(value["graph"]["segments"].as_array().unwrap().len(), 1);
        assert_eq!(value["graph"]["encoder"]["name"], "h264_mediacodec");
        assert_eq!(value["graph"]["graph_digest"].as_str().unwrap().len(), 16);
        assert!(value["summary"].as_str().unwrap().contains("120 frames"));
        assert_eq!(value["plan"]["watermark"], false);
    }

    #[test]
    fn render_graph_rejects_bad_range() {
        let created = state_from(create_project("그래프", 1080, 1920, 30));
        let state = created["state"].to_string();
        let settings = json!({ "range": { "start_ms": 5_000, "end_ms": 6_000 } });
        let err = render_graph(&state, &settings.to_string(), "macos").unwrap_err();
        let value: Value = serde_json::from_str(&err).expect("json");
        assert_eq!(value["error"]["code"], "invalid_range");
    }

    #[test]
    fn probe_bridge_normalizes_platform_result() {
        let probe = json!({
            "path": "/media/a.mp4",
            "duration_ms": 12_500,
            "width": 1080,
            "height": 1920,
            "fps": 29.97,
            "has_video": true,
            "has_audio": true,
            "source": "avfoundation"
        });
        let value = state_from(probe_media_info(&probe.to_string()));
        assert_eq!(value["clip_kind"], "video");
        assert_eq!(value["suggested_end_ms"], 12_500);
        assert!(value["summary"].as_str().unwrap().contains("1920"));
        assert_eq!(value["probe"]["source"], "avfoundation");

        let broken = probe_media_info("{").unwrap_err();
        let value: Value = serde_json::from_str(&broken).expect("json");
        assert_eq!(value["error"]["code"], "bad_probe");
    }

    #[test]
    fn probe_bridge_rejects_invalid_metadata() {
        let probe = json!({
            "path": "/media/a.mp4",
            "duration_ms": 0,
            "width": 1080,
            "height": 1920,
            "has_video": true,
            "fps": 30
        });
        let err = probe_media_info(&probe.to_string()).unwrap_err();
        let value: Value = serde_json::from_str(&err).expect("json");
        assert_eq!(value["error"]["code"], "invalid_probe");
    }

    #[test]
    fn export_job_bridge_tracks_progress_and_cancel() {
        let created = state_from(Ok(export_job_create("job-7", 240, Some(1_000))));
        assert_eq!(created["job"]["progress"]["state"], "queued");
        let job = created["job"].to_string();

        let advanced = state_from(export_job_event(
            &job,
            &json!({ "type": "progress", "completed_frames": 120, "at_ms": 5_000 }).to_string(),
        ));
        assert_eq!(advanced["applied"], true);
        assert_eq!(advanced["job"]["progress"]["state"], "rendering");
        assert_eq!(advanced["job"]["progress"]["percent"], 50.0);
        let advanced_job = advanced["job"].to_string();

        let canceled = state_from(export_job_cancel(&advanced_job, Some(6_000)));
        assert_eq!(canceled["job"]["progress"]["state"], "rendering");
        assert_eq!(canceled["job"]["progress"]["cancel_requested"], true);
        let canceled_job = canceled["job"].to_string();

        let confirmed = state_from(export_job_event(
            &canceled_job,
            &json!({ "type": "canceled", "at_ms": 6_500 }).to_string(),
        ));
        assert_eq!(confirmed["job"]["progress"]["state"], "canceled");

        let late = state_from(export_job_event(
            &confirmed["job"].to_string(),
            &json!({ "type": "completed" }).to_string(),
        ));
        assert_eq!(late["applied"], false);
        assert_eq!(late["job"]["progress"]["state"], "canceled");

        let bad = export_job_event(&job, "{\"type\":\"nope\"}").unwrap_err();
        let value: Value = serde_json::from_str(&bad).expect("json");
        assert_eq!(value["error"]["code"], "bad_event");
    }
}
