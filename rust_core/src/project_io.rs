//! 프로젝트 파일(`.muudproj`) 입출력.
//!
//! 저장 형식은 **사람이 읽을 수 있는 JSON** 이다. 이유:
//! * 디버깅/버전관리(diff)에 유리하다.
//! * 2단계에서 협업/부분 편집 기능을 붙일 때 그대로 쓸 수 있다.
//! * 미디어 파일은 절대 경로 대신 상대 경로를 쓸 수 있게 해 두었다(프로젝트 이동 대응).
//!
//! `schema_version`이 현재 지원 버전보다 높으면 **읽지 않고 거부**한다.
//! (UI가 무언가를 잘못 덮어써서 프로젝트를 망치는 것보다 안전하다.)

use std::path::Path;

use crate::error::ProjectIoError;
use crate::model::Project;

/// 현재 저장 스키마 버전.
pub const SCHEMA_VERSION: u32 = 1;

/// 프로젝트 파일 확장자.
pub const PROJECT_EXTENSION: &str = "muudproj";

/// 프로젝트를 pretty JSON으로 직렬화한다.
pub fn to_json(project: &Project) -> Result<String, ProjectIoError> {
    Ok(serde_json::to_string_pretty(project)?)
}

/// JSON에서 프로젝트를 읽는다. 스키마 버전을 확인한다.
pub fn from_json(text: &str) -> Result<Project, ProjectIoError> {
    let project: Project = serde_json::from_str(text)?;
    if project.schema_version > SCHEMA_VERSION {
        return Err(ProjectIoError::UnsupportedSchema {
            found: project.schema_version,
            supported: SCHEMA_VERSION,
        });
    }
    Ok(project)
}

/// 파일로 저장한다. 부모 디렉터리가 없으면 만든다.
pub fn save(project: &Project, path: impl AsRef<Path>) -> Result<(), ProjectIoError> {
    let path = path.as_ref();
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let text = to_json(project)?;
    std::fs::write(path, text)?;
    Ok(())
}

/// 파일에서 읽는다.
pub fn load(path: impl AsRef<Path>) -> Result<Project, ProjectIoError> {
    let text = std::fs::read_to_string(path.as_ref())?;
    from_json(&text)
}

/// 텍스트 파일(SRT 등) 저장.
pub fn write_text(path: impl AsRef<Path>, contents: &str) -> Result<(), ProjectIoError> {
    let path = path.as_ref();
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    std::fs::write(path, contents)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::editor::Editor;
    use crate::model::ClipKind;
    use crate::model::Resolution;

    #[test]
    fn json_roundtrip_preserves_state() {
        let mut editor = Editor::blank("왕복", Resolution::VERTICAL_1080P, 30);
        let video = editor.project.tracks[0].id.clone();
        editor
            .add_media_clip(&video, ClipKind::Video, "/media/a.mp4", 0, 2_000, None)
            .expect("clip");
        editor
            .add_subtitle(Some(0), Some(1_000), "자막")
            .expect("sub");

        let json = to_json(&editor.project).expect("serialize");
        let restored = from_json(&json).expect("deserialize");
        assert_eq!(restored, editor.project);
        assert_eq!(restored.duration_ms(), 2_000);
        assert_eq!(restored.subtitles.items.len(), 1);
    }

    #[test]
    fn unsupported_schema_is_rejected() {
        let mut project = Project::blank("x", Resolution::VERTICAL_1080P, 30);
        project.schema_version = SCHEMA_VERSION + 1;
        let json = serde_json::to_string(&project).expect("json");
        match from_json(&json) {
            Err(ProjectIoError::UnsupportedSchema { found, supported }) => {
                assert_eq!(found, SCHEMA_VERSION + 1);
                assert_eq!(supported, SCHEMA_VERSION);
            }
            other => panic!("예상과 다른 결과: {other:?}"),
        }
    }

    #[test]
    fn missing_optional_fields_get_defaults() {
        let json = r#"{
            "id": "prj-1",
            "name": "최소",
            "tracks": []
        }"#;
        let project = from_json(json).expect("parse");
        assert_eq!(project.schema_version, SCHEMA_VERSION);
        assert_eq!(project.fps, 30);
        assert_eq!(project.resolution, Resolution::VERTICAL_1080P);
        assert!(project.tracks.is_empty());
    }

    #[test]
    fn save_and_load_through_disk() {
        let dir = std::env::temp_dir().join("muud-edits-io-test");
        let path = dir.join(format!("{}.muudproj", std::process::id()));
        let project = Project::blank("디스크", Resolution::LANDSCAPE_1080P, 24);
        save(&project, &path).expect("save");
        let loaded = load(&path).expect("load");
        assert_eq!(loaded, project);
        assert_eq!(loaded.fps, 24);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn save_srt_writes_sidecar() {
        let mut editor = Editor::blank("srt", Resolution::VERTICAL_1080P, 30);
        editor
            .add_subtitle(Some(0), Some(1_000), "안녕")
            .expect("sub");
        let path = std::env::temp_dir().join(format!("muud-edits-{}.srt", std::process::id()));
        let written = editor.save_srt(&path).expect("save srt").expect("some");
        let text = std::fs::read_to_string(&written).expect("read");
        assert!(text.contains("00:00:00,000 --> 00:00:01,000"));
        assert!(text.contains("안녕"));
        let _ = std::fs::remove_file(&written);
    }
}
