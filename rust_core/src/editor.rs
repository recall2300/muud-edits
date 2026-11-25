//! 편집기 파사드.
//!
//! UI(Dart)는 이 타입 하나만 알면 된다.
//! * 상태: [`Editor::project`] + 히스토리
//! * 변경: [`Editor::apply`], [`Editor::undo`], [`Editor::redo`]
//! * 편의 빌더: `add_media_clip`, `split`, `add_subtitle` …
//!
//! 모든 변경은 [`EditCommand`]를 거치므로 되돌리기가 보장된다.
//! UI는 id를 직접 만들지 않고 편의 메서드가 발급한 id를 돌려받는다.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::commands::{CommandOutcome, EditCommand, History};
use crate::error::{EditError, ProjectIoError};
use crate::ids::{ClipId, SubtitleId, TrackId};
use crate::model::{Clip, ClipKind, Project, Resolution, TextOverlay, Track, TrackKind};
use crate::project_io;
use crate::subtitles::{SubtitleItem, SubtitlePatch};

/// 편집기 = 프로젝트 + 히스토리 + 저장 상태.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Editor {
    pub project: Project,
    #[serde(default)]
    pub history: History,
    /// 마지막 저장 이후 바뀐 내용이 있으면 true.
    #[serde(default)]
    pub dirty: bool,
    /// 연결된 프로젝트 파일 경로(있으면).
    #[serde(default)]
    pub file_path: Option<String>,
}

impl Editor {
    pub fn new(project: Project) -> Self {
        Self {
            project,
            history: History::default(),
            dirty: false,
            file_path: None,
        }
    }

    /// 숏폼 기본 프로젝트(Video/Audio/Overlay 트랙 3개).
    pub fn blank(name: impl Into<String>, resolution: Resolution, fps: u32) -> Self {
        Self::new(Project::blank(name, resolution, fps))
    }

    pub fn project(&self) -> &Project {
        &self.project
    }

    pub fn can_undo(&self) -> bool {
        self.history.can_undo()
    }

    pub fn can_redo(&self) -> bool {
        self.history.can_redo()
    }

    // ------------------------------------------------------------------ core ops

    /// 커맨드를 적용한다.
    pub fn apply(&mut self, command: EditCommand) -> Result<CommandOutcome, EditError> {
        let applied = self.history.apply(command, &mut self.project)?;
        self.dirty = true;
        self.project.touch();
        Ok(CommandOutcome::build(
            "apply",
            applied.label,
            &self.project,
            &self.history,
        ))
    }

    /// 마지막 커맨드를 되돌린다. 되돌릴 것이 없으면 `Ok(None)`.
    pub fn undo(&mut self) -> Result<Option<CommandOutcome>, EditError> {
        let Some(applied) = self.history.undo(&mut self.project)? else {
            return Ok(None);
        };
        self.dirty = true;
        self.project.touch();
        Ok(Some(CommandOutcome::build(
            "undo",
            applied.label,
            &self.project,
            &self.history,
        )))
    }

    /// 되돌린 커맨드를 다시 적용한다.
    pub fn redo(&mut self) -> Result<Option<CommandOutcome>, EditError> {
        let Some(applied) = self.history.redo(&mut self.project)? else {
            return Ok(None);
        };
        self.dirty = true;
        self.project.touch();
        Ok(Some(CommandOutcome::build(
            "redo",
            applied.label,
            &self.project,
            &self.history,
        )))
    }

    // ------------------------------------------------------------ clip builders

    /// 미디어 클립을 추가한다.
    ///
    /// `at_ms`가 없으면 트랙 끝에 이어 붙인다. 반환값은 새 클립 id.
    pub fn add_media_clip(
        &mut self,
        track_id: &TrackId,
        kind: ClipKind,
        source_path: impl Into<String>,
        start_ms: i64,
        end_ms: i64,
        at_ms: Option<i64>,
    ) -> Result<ClipId, EditError> {
        let track = self
            .project
            .track(track_id)
            .ok_or_else(|| EditError::TrackNotFound(track_id.to_string()))?;
        let offset = at_ms.unwrap_or_else(|| track.append_offset_ms());
        let id = self.project.mint_clip_id();
        let mut clip = Clip::new_media(id.clone(), kind, source_path, start_ms, end_ms);
        clip.timeline_offset_ms = offset;
        self.apply(EditCommand::AddClip {
            track_id: track_id.clone(),
            clip,
        })?;
        Ok(id)
    }

    /// 미디어 클립을 추가하면서 소스 전체 길이를 함께 기록한다(트림 검증에 사용).
    pub fn add_media_clip_with_duration(
        &mut self,
        track_id: &TrackId,
        kind: ClipKind,
        source_path: impl Into<String>,
        source_duration_ms: i64,
        at_ms: Option<i64>,
    ) -> Result<ClipId, EditError> {
        let track = self
            .project
            .track(track_id)
            .ok_or_else(|| EditError::TrackNotFound(track_id.to_string()))?;
        let offset = at_ms.unwrap_or_else(|| track.append_offset_ms());
        let id = self.project.mint_clip_id();
        let mut clip = Clip::new_media(id.clone(), kind, source_path, 0, source_duration_ms);
        clip.timeline_offset_ms = offset;
        clip.source_duration_ms = Some(source_duration_ms);
        self.apply(EditCommand::AddClip {
            track_id: track_id.clone(),
            clip,
        })?;
        Ok(id)
    }

    /// 텍스트/자막성 오버레이 클립을 추가한다.
    pub fn add_text_clip(
        &mut self,
        track_id: &TrackId,
        text: TextOverlay,
        duration_ms: i64,
        at_ms: i64,
    ) -> Result<ClipId, EditError> {
        let id = self.project.mint_clip_id();
        let mut clip = Clip::new_text(id.clone(), text, duration_ms);
        clip.timeline_offset_ms = at_ms;
        self.apply(EditCommand::AddClip {
            track_id: track_id.clone(),
            clip,
        })?;
        Ok(id)
    }

    /// 클립을 `at_ms`에서 자르고, 오른쪽 조각의 id를 돌려준다.
    pub fn split(
        &mut self,
        track_id: &TrackId,
        clip_id: &ClipId,
        at_ms: i64,
    ) -> Result<ClipId, EditError> {
        let right_id = self.project.mint_clip_id();
        self.apply(EditCommand::SplitClip {
            track_id: track_id.clone(),
            clip_id: clip_id.clone(),
            at_timeline_ms: at_ms,
            right_clip_id: Some(right_id.clone()),
        })?;
        Ok(right_id)
    }

    /// 트림. 절대값으로 소스 인/아웃점을 지정한다.
    pub fn trim(
        &mut self,
        track_id: &TrackId,
        clip_id: &ClipId,
        start_ms: Option<i64>,
        end_ms: Option<i64>,
    ) -> Result<(), EditError> {
        self.apply(EditCommand::TrimClip {
            track_id: track_id.clone(),
            clip_id: clip_id.clone(),
            start_ms,
            end_ms,
            timeline_offset_ms: None,
        })?;
        Ok(())
    }

    /// 클립 삭제.
    pub fn remove_clip(&mut self, track_id: &TrackId, clip_id: &ClipId) -> Result<(), EditError> {
        self.apply(EditCommand::RemoveClip {
            track_id: track_id.clone(),
            clip_id: clip_id.clone(),
        })?;
        Ok(())
    }

    /// 클립 이동.
    pub fn move_clip(
        &mut self,
        track_id: &TrackId,
        clip_id: &ClipId,
        to_track: Option<TrackId>,
        at_ms: i64,
    ) -> Result<(), EditError> {
        self.apply(EditCommand::MoveClip {
            track_id: track_id.clone(),
            clip_id: clip_id.clone(),
            to_track_id: to_track,
            timeline_offset_ms: at_ms,
        })?;
        Ok(())
    }

    pub fn set_speed(
        &mut self,
        track_id: &TrackId,
        clip_id: &ClipId,
        speed: f32,
    ) -> Result<(), EditError> {
        self.apply(EditCommand::SetClipSpeed {
            track_id: track_id.clone(),
            clip_id: clip_id.clone(),
            speed,
        })?;
        Ok(())
    }

    pub fn set_volume(
        &mut self,
        track_id: &TrackId,
        clip_id: &ClipId,
        volume: f32,
    ) -> Result<(), EditError> {
        self.apply(EditCommand::SetClipVolume {
            track_id: track_id.clone(),
            clip_id: clip_id.clone(),
            volume,
        })?;
        Ok(())
    }

    /// 새 트랙 추가(종류별 자동 이름).
    pub fn add_track(&mut self, kind: TrackKind) -> Result<TrackId, EditError> {
        let name = self.project.unique_track_name(kind);
        let id = self.project.mint_track_id();
        self.apply(EditCommand::AddTrack {
            track: Track::new(id.clone(), name, kind),
        })?;
        Ok(id)
    }

    // ---------------------------------------------------------------- subtitles

    /// 자막 추가. `at_start_ms`가 없으면 마지막 자막 뒤(300ms 간격)에 붙인다.
    pub fn add_subtitle(
        &mut self,
        start_ms: Option<i64>,
        end_ms: Option<i64>,
        text: impl Into<String>,
    ) -> Result<SubtitleId, EditError> {
        let id = self.project.mint_subtitle_id();
        let start = start_ms.unwrap_or_else(|| self.project.subtitles.append_start_ms(300));
        let end = end_ms.unwrap_or(start + 2_000);
        let item = SubtitleItem::new(id.clone(), start, end, text);
        self.apply(EditCommand::AddSubtitle { item })?;
        Ok(id)
    }

    /// 자동 자막(Whisper 등) 결과를 한 번에 삽입한다.
    pub fn add_auto_subtitles(
        &mut self,
        segments: Vec<(i64, i64, String, Option<f32>)>,
    ) -> Result<usize, EditError> {
        let mut commands = Vec::with_capacity(segments.len());
        let mut ids = Vec::with_capacity(segments.len());
        for (start, end, text, confidence) in segments {
            let id = self.project.mint_subtitle_id();
            let mut item = SubtitleItem::new(id.clone(), start, end, text);
            item.auto_generated = true;
            item.confidence = confidence;
            ids.push(id);
            commands.push(EditCommand::AddSubtitle { item });
        }
        if commands.is_empty() {
            return Ok(0);
        }
        let count = commands.len();
        self.apply(EditCommand::Batch { commands })?;
        Ok(count)
    }

    /// 자막 부분 수정.
    pub fn update_subtitle(
        &mut self,
        id: &SubtitleId,
        patch: SubtitlePatch,
    ) -> Result<(), EditError> {
        self.apply(EditCommand::UpdateSubtitle {
            id: id.clone(),
            patch,
        })?;
        Ok(())
    }

    pub fn remove_subtitle(&mut self, id: &SubtitleId) -> Result<(), EditError> {
        self.apply(EditCommand::RemoveSubtitle { id: id.clone() })?;
        Ok(())
    }

    // ------------------------------------------------------------- persistence

    pub fn to_json(&self) -> Result<String, ProjectIoError> {
        project_io::to_json(&self.project)
    }

    /// 프로젝트 파일 저장(`.muudproj`).
    pub fn save_to(&mut self, path: impl AsRef<Path>) -> Result<(), ProjectIoError> {
        project_io::save(&self.project, &path)?;
        self.dirty = false;
        self.file_path = Some(path.as_ref().to_string_lossy().to_string());
        Ok(())
    }

    /// 프로젝트 파일 불러오기.
    pub fn load_from(path: impl AsRef<Path>) -> Result<Self, ProjectIoError> {
        let project = project_io::load(&path)?;
        let mut editor = Self::new(project);
        editor.file_path = Some(path.as_ref().to_string_lossy().to_string());
        Ok(editor)
    }

    /// 자막을 SRT로 저장하고, 저장한 경로를 돌려준다(자막이 없으면 None).
    pub fn save_srt(&self, path: impl AsRef<Path>) -> Result<Option<String>, ProjectIoError> {
        if self.project.subtitles.items.is_empty() {
            return Ok(None);
        }
        let srt = self.project.subtitles.to_srt();
        project_io::write_text(&path, &srt)?;
        Ok(Some(path.as_ref().to_string_lossy().to_string()))
    }

    pub fn save_vtt(&self, path: impl AsRef<Path>) -> Result<Option<String>, ProjectIoError> {
        if self.project.subtitles.items.is_empty() {
            return Ok(None);
        }
        let vtt = self.project.subtitles.to_vtt();
        project_io::write_text(&path, &vtt)?;
        Ok(Some(path.as_ref().to_string_lossy().to_string()))
    }

    /// UI 요약.
    pub fn summary(&self) -> ProjectSummary {
        ProjectSummary::from_editor(self)
    }
}

/// UI 목록/헤더에 쓰는 요약.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ProjectSummary {
    pub id: String,
    pub name: String,
    pub resolution: Resolution,
    pub fps: u32,
    pub duration_ms: i64,
    pub duration_label: String,
    pub track_count: usize,
    pub clip_count: usize,
    pub subtitle_count: usize,
    pub tracks: Vec<TrackSummary>,
    pub can_undo: bool,
    pub can_redo: bool,
    pub undo_label: Option<String>,
    pub redo_label: Option<String>,
    pub undo_depth: usize,
    pub redo_depth: usize,
    pub dirty: bool,
    pub file_path: Option<String>,
    pub watermark: bool,
}

/// 트랙 한 줄 요약.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TrackSummary {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub clip_count: usize,
    pub duration_ms: i64,
    pub muted: bool,
    pub hidden: bool,
    pub locked: bool,
}

impl ProjectSummary {
    pub fn from_editor(editor: &Editor) -> Self {
        let project = &editor.project;
        let duration = project.duration_ms();
        Self {
            id: project.id.clone(),
            name: project.name.clone(),
            resolution: project.resolution,
            fps: project.fps,
            duration_ms: duration,
            duration_label: crate::timeline::format_frame_timecode(duration, project.fps),
            track_count: project.tracks.len(),
            clip_count: project.tracks.iter().map(|t| t.clips.len()).sum(),
            subtitle_count: project.subtitles.items.len(),
            tracks: project
                .tracks
                .iter()
                .map(|t| TrackSummary {
                    id: t.id.to_string(),
                    name: t.name.clone(),
                    kind: t.kind.as_str().to_string(),
                    clip_count: t.clips.len(),
                    duration_ms: t.duration_ms(),
                    muted: t.muted,
                    hidden: t.hidden,
                    locked: t.locked,
                })
                .collect(),
            can_undo: editor.can_undo(),
            can_redo: editor.can_redo(),
            undo_label: editor.history.peek_undo_label().map(str::to_string),
            redo_label: editor.history.peek_redo_label().map(str::to_string),
            undo_depth: editor.history.undo_depth(),
            redo_depth: editor.history.redo_depth(),
            dirty: editor.dirty,
            file_path: editor.file_path.clone(),
            watermark: project.export.watermark,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn editor() -> Editor {
        Editor::blank("데모", Resolution::VERTICAL_1080P, 30)
    }

    #[test]
    fn add_split_undo_redo_flow() {
        let mut e = editor();
        let video = e.project.tracks[0].id.clone();
        let clip = e
            .add_media_clip(&video, ClipKind::Video, "/media/a.mp4", 0, 4_000, None)
            .expect("add");
        assert_eq!(e.project.duration_ms(), 4_000);
        assert!(e.can_undo());

        let right = e.split(&video, &clip, 1_500).expect("split");
        assert_eq!(e.project.tracks[0].clips.len(), 2);
        assert_eq!(e.project.duration_ms(), 4_000);

        e.undo().expect("undo").expect("some");
        assert_eq!(e.project.tracks[0].clips.len(), 1);
        assert!(e.project.tracks[0].clip(&right).is_none());

        e.redo().expect("redo").expect("some");
        assert_eq!(e.project.tracks[0].clips.len(), 2);
    }

    #[test]
    fn append_places_clips_one_after_another() {
        let mut e = editor();
        let video = e.project.tracks[0].id.clone();
        e.add_media_clip(&video, ClipKind::Video, "/a.mp4", 0, 1_000, None)
            .expect("a");
        e.add_media_clip(&video, ClipKind::Video, "/b.mp4", 0, 2_000, None)
            .expect("b");
        let clips = &e.project.tracks[0].clips;
        assert_eq!(clips[0].timeline_offset_ms, 0);
        assert_eq!(clips[1].timeline_offset_ms, 1_000);
        assert_eq!(e.project.duration_ms(), 3_000);
    }

    #[test]
    fn auto_subtitles_are_atomic_and_marked() {
        let mut e = editor();
        let count = e
            .add_auto_subtitles(vec![
                (0, 1_200, "첫 문장".into(), Some(0.98)),
                (1_200, 2_400, "둘째 문장".into(), Some(0.91)),
            ])
            .expect("auto subs");
        assert_eq!(count, 2);
        assert_eq!(e.project.subtitles.items.len(), 2);
        assert!(e.project.subtitles.items[0].auto_generated);
        assert!((e.project.subtitles.items[0].confidence.unwrap() - 0.98).abs() < 0.001);

        e.undo().expect("undo").expect("some");
        assert_eq!(e.project.subtitles.items.len(), 0, "한 번에 되돌아간다");
    }

    #[test]
    fn summary_reports_state() {
        let mut e = editor();
        let video = e.project.tracks[0].id.clone();
        e.add_media_clip(&video, ClipKind::Video, "/a.mp4", 0, 1_500, None)
            .expect("add");
        let summary = e.summary();
        assert_eq!(summary.track_count, 3);
        assert_eq!(summary.clip_count, 1);
        assert_eq!(summary.duration_ms, 1_500);
        assert_eq!(summary.duration_label, "00:00:01:15");
        assert!(summary.can_undo);
        assert!(!summary.watermark);
        assert_eq!(summary.tracks[0].kind, "video");
    }

    #[test]
    fn dirty_flag_clears_on_save() {
        let mut e = editor();
        assert!(!e.dirty);
        let video = e.project.tracks[0].id.clone();
        e.add_media_clip(&video, ClipKind::Video, "/a.mp4", 0, 1_000, None)
            .expect("add");
        assert!(e.dirty);
        e.dirty = false;
        assert!(!e.dirty);
    }

    #[test]
    fn undo_when_empty_is_none() {
        let mut e = editor();
        assert!(e.undo().expect("undo").is_none());
        assert!(e.redo().expect("redo").is_none());
    }
}
