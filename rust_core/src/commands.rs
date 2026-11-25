//! 되돌리기 가능한 편집 커맨드.
//!
//! ## 규약
//! * 커맨드는 **모든 검증을 변이 전에** 끝낸다. 실패하면 프로젝트는 그대로다.
//!   (예외: [`EditCommand::Batch`]는 스크래치 복제본에서 먼저 시험 적용한다.)
//! * `apply`는 자신의 **역 커맨드**를 돌려준다. 역 커맨드를 적용하면 원상복구된다.
//! * 역 커맨드도 같은 규칙을 따르므로, 되돌리기의 되돌리기(=redo)가 자연스럽게 성립한다.
//!
//! ```text
//! [AddClip] --apply--> inverse [RemoveClip]
//!     ^                                     |
//!     +----------- apply(inverse) ----------+
//! ```
//!
//! 타임라인 히스토리는 [`History`]가 스택 두 개로 관리한다.

use serde::{Deserialize, Serialize};

use crate::error::EditError;
use crate::ids::{ClipId, SubtitleId, TrackId};
use crate::model::{Clip, ClipKind, Project, TextOverlay, Track};
use crate::subtitles::{SubtitleItem, SubtitlePatch};
use crate::timeline;

fn default_limit() -> usize {
    200
}

/// 편집 커맨드 하나.
///
/// JSON에서는 `{"type": "add_clip", "track_id": "...", "clip": {...}}` 처럼
/// 외부 태그 방식으로 직렬화된다(Dart에서 만들기 쉽다).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EditCommand {
    /// 트랙 추가.
    AddTrack { track: Track },
    /// 트랙 삭제(클립도 함께 사라진다. 되돌리면 복구된다).
    RemoveTrack { track_id: TrackId },
    /// 트랙 이름 변경.
    RenameTrack { track_id: TrackId, name: String },
    /// 트랙 상태(음소거/숨김/잠금) 변경.
    SetTrackState {
        track_id: TrackId,
        #[serde(default)]
        muted: Option<bool>,
        #[serde(default)]
        hidden: Option<bool>,
        #[serde(default)]
        locked: Option<bool>,
    },
    /// 클립 추가.
    AddClip { track_id: TrackId, clip: Clip },
    /// 클립 삭제.
    RemoveClip { track_id: TrackId, clip_id: ClipId },
    /// 클립 트림(소스 인/아웃점, 타임라인 위치를 절대값으로 지정).
    TrimClip {
        track_id: TrackId,
        clip_id: ClipId,
        #[serde(default)]
        start_ms: Option<i64>,
        #[serde(default)]
        end_ms: Option<i64>,
        #[serde(default)]
        timeline_offset_ms: Option<i64>,
    },
    /// 클립 이동(같은 트랙 내 이동 또는 다른 트랙으로 이동).
    MoveClip {
        track_id: TrackId,
        clip_id: ClipId,
        #[serde(default)]
        to_track_id: Option<TrackId>,
        timeline_offset_ms: i64,
    },
    /// 클립 분할. `right_clip_id`를 주면 오른쪽 조각의 id를 고정할 수 있다.
    SplitClip {
        track_id: TrackId,
        clip_id: ClipId,
        at_timeline_ms: i64,
        #[serde(default)]
        right_clip_id: Option<ClipId>,
    },
    /// 재생 속도 변경.
    SetClipSpeed {
        track_id: TrackId,
        clip_id: ClipId,
        speed: f32,
    },
    /// 클립 볼륨 변경.
    SetClipVolume {
        track_id: TrackId,
        clip_id: ClipId,
        volume: f32,
    },
    /// 클립 불투명도 변경.
    SetClipOpacity {
        track_id: TrackId,
        clip_id: ClipId,
        opacity: f32,
    },
    /// 클립 켜기/끄기(삭제하지 않고 타임라인에서 빼기).
    SetClipEnabled {
        track_id: TrackId,
        clip_id: ClipId,
        enabled: bool,
    },
    /// 텍스트 클립의 내용/스타일 교체.
    SetClipText {
        track_id: TrackId,
        clip_id: ClipId,
        text: TextOverlay,
    },
    /// 페이드 인/아웃 설정.
    SetClipFades {
        track_id: TrackId,
        clip_id: ClipId,
        fade_in_ms: u32,
        fade_out_ms: u32,
    },
    /// 자막 추가.
    AddSubtitle { item: SubtitleItem },
    /// 자막 부분 수정.
    UpdateSubtitle {
        id: SubtitleId,
        patch: SubtitlePatch,
    },
    /// 자막 삭제.
    RemoveSubtitle { id: SubtitleId },
    /// 여러 커맨드를 원자적으로 적용(역순 역 커맨드 묶음으로 되돌린다).
    Batch { commands: Vec<EditCommand> },
}

impl EditCommand {
    /// 로그/UI에 쓰는 안정적인 키.
    pub fn label(&self) -> &'static str {
        match self {
            EditCommand::AddTrack { .. } => "add_track",
            EditCommand::RemoveTrack { .. } => "remove_track",
            EditCommand::RenameTrack { .. } => "rename_track",
            EditCommand::SetTrackState { .. } => "set_track_state",
            EditCommand::AddClip { .. } => "add_clip",
            EditCommand::RemoveClip { .. } => "remove_clip",
            EditCommand::TrimClip { .. } => "trim_clip",
            EditCommand::MoveClip { .. } => "move_clip",
            EditCommand::SplitClip { .. } => "split_clip",
            EditCommand::SetClipSpeed { .. } => "set_clip_speed",
            EditCommand::SetClipVolume { .. } => "set_clip_volume",
            EditCommand::SetClipOpacity { .. } => "set_clip_opacity",
            EditCommand::SetClipEnabled { .. } => "set_clip_enabled",
            EditCommand::SetClipText { .. } => "set_clip_text",
            EditCommand::SetClipFades { .. } => "set_clip_fades",
            EditCommand::AddSubtitle { .. } => "add_subtitle",
            EditCommand::UpdateSubtitle { .. } => "update_subtitle",
            EditCommand::RemoveSubtitle { .. } => "remove_subtitle",
            EditCommand::Batch { .. } => "batch",
        }
    }

    /// 커맨드가 주로 건드리는 대상 id(선택). UI가 해당 클립을 선택/스크롤할 때 쓴다.
    pub fn primary_target(&self) -> Option<String> {
        match self {
            EditCommand::AddClip { track_id, .. }
            | EditCommand::RemoveClip { track_id, .. }
            | EditCommand::TrimClip { track_id, .. }
            | EditCommand::MoveClip { track_id, .. }
            | EditCommand::SplitClip { track_id, .. }
            | EditCommand::SetClipSpeed { track_id, .. }
            | EditCommand::SetClipVolume { track_id, .. }
            | EditCommand::SetClipOpacity { track_id, .. }
            | EditCommand::SetClipEnabled { track_id, .. }
            | EditCommand::SetClipText { track_id, .. }
            | EditCommand::SetClipFades { track_id, .. } => Some(track_id.to_string()),
            EditCommand::AddSubtitle { item } => Some(item.id.to_string()),
            EditCommand::UpdateSubtitle { id, .. } | EditCommand::RemoveSubtitle { id } => {
                Some(id.to_string())
            }
            EditCommand::AddTrack { track } => Some(track.id.to_string()),
            EditCommand::RemoveTrack { track_id }
            | EditCommand::RenameTrack { track_id, .. }
            | EditCommand::SetTrackState { track_id, .. } => Some(track_id.to_string()),
            EditCommand::Batch { .. } => None,
        }
    }

    /// 커맨드를 적용하고 역 커맨드를 돌려준다.
    pub fn apply(self, project: &mut Project) -> Result<EditCommand, EditError> {
        match self {
            // ---------------------------------------------------------------- tracks
            EditCommand::AddTrack { track } => {
                if project.track_index(&track.id).is_some() {
                    return Err(EditError::Invalid(format!(
                        "이미 존재하는 트랙 id입니다: {}",
                        track.id
                    )));
                }
                for clip in &track.clips {
                    clip.validate()?;
                    if !track.kind.accepts(clip.kind) {
                        return Err(EditError::IncompatibleTrackKind {
                            track: track.kind.as_str().to_string(),
                            clip: clip.kind.as_str().to_string(),
                        });
                    }
                }
                let track_id = track.id.clone();
                project.tracks.push(track);
                Ok(EditCommand::RemoveTrack { track_id })
            }

            EditCommand::RemoveTrack { track_id } => {
                let index = project
                    .track_index(&track_id)
                    .ok_or_else(|| EditError::TrackNotFound(track_id.to_string()))?;
                if project.tracks[index].locked {
                    return Err(EditError::TrackLocked(track_id.to_string()));
                }
                let removed = project.tracks.remove(index);
                Ok(EditCommand::AddTrack { track: removed })
            }

            EditCommand::RenameTrack { track_id, name } => {
                if name.trim().is_empty() {
                    return Err(EditError::Invalid("트랙 이름이 비어 있습니다".into()));
                }
                let previous = {
                    let track = project.track_checked(&track_id)?;
                    track.name.clone()
                };
                let track = project
                    .track_mut(&track_id)
                    .ok_or_else(|| EditError::TrackNotFound(track_id.to_string()))?;
                track.name = name;
                Ok(EditCommand::RenameTrack {
                    track_id,
                    name: previous,
                })
            }

            EditCommand::SetTrackState {
                track_id,
                muted,
                hidden,
                locked,
            } => {
                let (prev_muted, prev_hidden, prev_locked) = {
                    let track = project.track_checked(&track_id)?;
                    (track.muted, track.hidden, track.locked)
                };
                let track = project
                    .track_mut(&track_id)
                    .ok_or_else(|| EditError::TrackNotFound(track_id.to_string()))?;
                if let Some(v) = muted {
                    track.muted = v;
                }
                if let Some(v) = hidden {
                    track.hidden = v;
                }
                if let Some(v) = locked {
                    track.locked = v;
                }
                Ok(EditCommand::SetTrackState {
                    track_id,
                    muted: muted.map(|_| prev_muted),
                    hidden: hidden.map(|_| prev_hidden),
                    locked: locked.map(|_| prev_locked),
                })
            }

            // ----------------------------------------------------------------- clips
            EditCommand::AddClip { track_id, clip } => {
                clip.validate()?;
                if project.find_clip(&clip.id).is_some() {
                    return Err(EditError::Invalid(format!(
                        "이미 존재하는 클립 id입니다: {}",
                        clip.id
                    )));
                }
                let clip_id = clip.id.clone();
                {
                    let track = project.track_editable(&track_id)?;
                    if !track.kind.accepts(clip.kind) {
                        return Err(EditError::IncompatibleTrackKind {
                            track: track.kind.as_str().to_string(),
                            clip: clip.kind.as_str().to_string(),
                        });
                    }
                    track.check_placement(clip.timeline_offset_ms, clip.timeline_end_ms(), None)?;
                    track.clips.push(clip);
                    track.sort_clips();
                }
                Ok(EditCommand::RemoveClip { track_id, clip_id })
            }

            EditCommand::RemoveClip { track_id, clip_id } => {
                let removed = {
                    let track = project.track_editable(&track_id)?;
                    let index = track
                        .clip_index(&clip_id)
                        .ok_or_else(|| EditError::ClipNotFound(clip_id.to_string()))?;
                    track.clips.remove(index)
                };
                Ok(EditCommand::AddClip {
                    track_id,
                    clip: removed,
                })
            }

            EditCommand::TrimClip {
                track_id,
                clip_id,
                start_ms,
                end_ms,
                timeline_offset_ms,
            } => {
                let current = read_clip(project, &track_id, &clip_id)?;
                let mut next = current.clone();
                if let Some(v) = start_ms {
                    if v < 0 {
                        return Err(EditError::NegativeTime { value: v });
                    }
                    next.start_ms = v;
                }
                if let Some(v) = end_ms {
                    if v < 0 {
                        return Err(EditError::NegativeTime { value: v });
                    }
                    next.end_ms = v;
                }
                if let Some(v) = timeline_offset_ms {
                    if v < 0 {
                        return Err(EditError::NegativeTime { value: v });
                    }
                    next.timeline_offset_ms = v;
                }
                next.validate()?;
                {
                    let track = project.track_editable(&track_id)?;
                    track.check_placement(
                        next.timeline_offset_ms,
                        next.timeline_end_ms(),
                        Some(&clip_id),
                    )?;
                }
                write_clip(project, &track_id, next)?;
                Ok(EditCommand::TrimClip {
                    track_id,
                    clip_id,
                    start_ms: Some(current.start_ms),
                    end_ms: Some(current.end_ms),
                    timeline_offset_ms: Some(current.timeline_offset_ms),
                })
            }

            EditCommand::MoveClip {
                track_id,
                clip_id,
                to_track_id,
                timeline_offset_ms,
            } => {
                if timeline_offset_ms < 0 {
                    return Err(EditError::NegativeTime {
                        value: timeline_offset_ms,
                    });
                }
                let target_id = to_track_id.clone().unwrap_or_else(|| track_id.clone());
                let current = read_clip(project, &track_id, &clip_id)?;
                {
                    let target = project.track_editable(&target_id)?;
                    if !target.kind.accepts(current.kind) {
                        return Err(EditError::IncompatibleTrackKind {
                            track: target.kind.as_str().to_string(),
                            clip: current.kind.as_str().to_string(),
                        });
                    }
                    let ignore = if target_id == track_id {
                        Some(&clip_id)
                    } else {
                        None
                    };
                    target.check_placement(
                        timeline_offset_ms,
                        timeline_offset_ms + current.timeline_duration_ms(),
                        ignore,
                    )?;
                }
                if target_id != track_id {
                    // 소스 트랙도 잠금 검사가 필요하다.
                    project.track_editable(&track_id)?;
                }
                // 이동 실행
                let mut moved = remove_clip(project, &track_id, &clip_id)?;
                moved.timeline_offset_ms = timeline_offset_ms;
                push_clip(project, &target_id, moved)?;
                Ok(EditCommand::MoveClip {
                    track_id: target_id,
                    clip_id,
                    to_track_id: Some(track_id),
                    timeline_offset_ms: current.timeline_offset_ms,
                })
            }

            EditCommand::SplitClip {
                track_id,
                clip_id,
                at_timeline_ms,
                right_clip_id,
            } => {
                let current = read_clip(project, &track_id, &clip_id)?;
                if current.kind == ClipKind::Text {
                    return Err(EditError::Unsupported("텍스트 클립은 분할할 수 없습니다"));
                }
                let point = timeline::split_point(&current, at_timeline_ms)?;

                let mut left = current.clone();
                left.end_ms = point.source_ms;

                let mut right = current.clone();
                right.id = match right_clip_id {
                    Some(id) => id,
                    None => project.mint_clip_id(),
                };
                if right.id == current.id {
                    return Err(EditError::Invalid(
                        "분할 조각의 id가 원본과 같습니다".into(),
                    ));
                }
                if project.find_clip(&right.id).is_some() {
                    return Err(EditError::Invalid(format!(
                        "이미 존재하는 클립 id입니다: {}",
                        right.id
                    )));
                }
                right.start_ms = point.source_ms;
                right.timeline_offset_ms = left.timeline_end_ms();
                right.validate()?;
                left.validate()?;

                let right_id = right.id.clone();
                write_clip(project, &track_id, left)?;
                push_clip(project, &track_id, right)?;

                // 되돌리기: 오른쪽 조각을 지우고 왼쪽을 원래 끝점으로 복원.
                Ok(EditCommand::Batch {
                    commands: vec![
                        EditCommand::RemoveClip {
                            track_id: track_id.clone(),
                            clip_id: right_id,
                        },
                        EditCommand::TrimClip {
                            track_id,
                            clip_id,
                            start_ms: Some(current.start_ms),
                            end_ms: Some(current.end_ms),
                            timeline_offset_ms: Some(current.timeline_offset_ms),
                        },
                    ],
                })
            }

            EditCommand::SetClipSpeed {
                track_id,
                clip_id,
                speed,
            } => {
                let current = read_clip(project, &track_id, &clip_id)?;
                let mut next = current.clone();
                next.speed = speed;
                next.validate()?;
                {
                    let track = project.track_editable(&track_id)?;
                    track.check_placement(
                        next.timeline_offset_ms,
                        next.timeline_end_ms(),
                        Some(&clip_id),
                    )?;
                }
                write_clip(project, &track_id, next)?;
                Ok(EditCommand::SetClipSpeed {
                    track_id,
                    clip_id,
                    speed: current.speed,
                })
            }

            EditCommand::SetClipVolume {
                track_id,
                clip_id,
                volume,
            } => {
                let current = read_clip(project, &track_id, &clip_id)?;
                let mut next = current.clone();
                next.volume = volume;
                next.validate()?;
                write_clip(project, &track_id, next)?;
                Ok(EditCommand::SetClipVolume {
                    track_id,
                    clip_id,
                    volume: current.volume,
                })
            }

            EditCommand::SetClipOpacity {
                track_id,
                clip_id,
                opacity,
            } => {
                let current = read_clip(project, &track_id, &clip_id)?;
                let mut next = current.clone();
                next.opacity = opacity;
                next.validate()?;
                write_clip(project, &track_id, next)?;
                Ok(EditCommand::SetClipOpacity {
                    track_id,
                    clip_id,
                    opacity: current.opacity,
                })
            }

            EditCommand::SetClipEnabled {
                track_id,
                clip_id,
                enabled,
            } => {
                let current = read_clip(project, &track_id, &clip_id)?;
                let mut next = current.clone();
                next.enabled = enabled;
                write_clip(project, &track_id, next)?;
                Ok(EditCommand::SetClipEnabled {
                    track_id,
                    clip_id,
                    enabled: current.enabled,
                })
            }

            EditCommand::SetClipText {
                track_id,
                clip_id,
                text,
            } => {
                let current = read_clip(project, &track_id, &clip_id)?;
                if current.kind != ClipKind::Text {
                    return Err(EditError::Unsupported("텍스트 클립에서만 쓸 수 있습니다"));
                }
                if text.content.trim().is_empty() {
                    return Err(EditError::EmptyText);
                }
                let previous = current
                    .text
                    .clone()
                    .ok_or(EditError::Unsupported("텍스트가 없는 클립입니다"))?;
                let mut next = current.clone();
                next.text = Some(text);
                next.validate()?;
                write_clip(project, &track_id, next)?;
                Ok(EditCommand::SetClipText {
                    track_id,
                    clip_id,
                    text: previous,
                })
            }

            EditCommand::SetClipFades {
                track_id,
                clip_id,
                fade_in_ms,
                fade_out_ms,
            } => {
                let current = read_clip(project, &track_id, &clip_id)?;
                let mut next = current.clone();
                next.fade_in_ms = fade_in_ms;
                next.fade_out_ms = fade_out_ms;
                write_clip(project, &track_id, next)?;
                Ok(EditCommand::SetClipFades {
                    track_id,
                    clip_id,
                    fade_in_ms: current.fade_in_ms,
                    fade_out_ms: current.fade_out_ms,
                })
            }

            // ------------------------------------------------------------- subtitles
            EditCommand::AddSubtitle { item } => {
                item.validate()?;
                if project.subtitles.item(&item.id).is_some() {
                    return Err(EditError::Invalid(format!(
                        "이미 존재하는 자막 id입니다: {}",
                        item.id
                    )));
                }
                project
                    .subtitles
                    .check_placement(item.start_ms, item.end_ms, None)?;
                let id = item.id.clone();
                project.subtitles.items.push(item);
                project.subtitles.sort();
                Ok(EditCommand::RemoveSubtitle { id })
            }

            EditCommand::UpdateSubtitle { id, patch } => {
                let current = project
                    .subtitles
                    .item(&id)
                    .cloned()
                    .ok_or_else(|| EditError::SubtitleNotFound(id.to_string()))?;
                if patch.is_empty() {
                    return Err(EditError::Invalid("변경 내용이 없습니다".into()));
                }
                let next = patch.apply_to(&current);
                next.validate()?;
                project
                    .subtitles
                    .check_placement(next.start_ms, next.end_ms, Some(&id))?;
                let inverse = patch.inverse_of(&current);
                if let Some(index) = project.subtitles.item_index(&id) {
                    project.subtitles.items[index] = next;
                    project.subtitles.sort();
                }
                Ok(EditCommand::UpdateSubtitle { id, patch: inverse })
            }

            EditCommand::RemoveSubtitle { id } => {
                let index = project
                    .subtitles
                    .item_index(&id)
                    .ok_or_else(|| EditError::SubtitleNotFound(id.to_string()))?;
                let removed = project.subtitles.items.remove(index);
                Ok(EditCommand::AddSubtitle { item: removed })
            }

            // ----------------------------------------------------------------- batch
            EditCommand::Batch { commands } => {
                if commands.is_empty() {
                    return Err(EditError::Invalid("빈 배치입니다".into()));
                }
                // 원자성: 복제본에서 먼저 전부 적용해 보고, 성공하면 반영한다.
                let mut scratch = project.clone();
                let mut inverses = Vec::with_capacity(commands.len());
                for command in commands {
                    let inverse = command.apply(&mut scratch)?;
                    inverses.push(inverse);
                }
                *project = scratch;
                inverses.reverse();
                Ok(EditCommand::Batch { commands: inverses })
            }
        }
    }
}

fn read_clip(project: &Project, track_id: &TrackId, clip_id: &ClipId) -> Result<Clip, EditError> {
    project
        .track_checked(track_id)?
        .clip(clip_id)
        .cloned()
        .ok_or_else(|| EditError::ClipNotFound(clip_id.to_string()))
}

fn write_clip(project: &mut Project, track_id: &TrackId, clip: Clip) -> Result<(), EditError> {
    let track = project.track_editable(track_id)?;
    let index = track
        .clip_index(&clip.id)
        .ok_or_else(|| EditError::ClipNotFound(clip.id.to_string()))?;
    track.clips[index] = clip;
    track.sort_clips();
    Ok(())
}

fn push_clip(project: &mut Project, track_id: &TrackId, clip: Clip) -> Result<(), EditError> {
    let clip_id = clip.id.clone();
    let track = project.track_editable(track_id)?;
    if track.clip_index(&clip_id).is_some() {
        return Err(EditError::Invalid(format!(
            "이미 존재하는 클립 id입니다: {clip_id}"
        )));
    }
    track.clips.push(clip);
    track.sort_clips();
    Ok(())
}

fn remove_clip(
    project: &mut Project,
    track_id: &TrackId,
    clip_id: &ClipId,
) -> Result<Clip, EditError> {
    let track = project.track_editable(track_id)?;
    let index = track
        .clip_index(clip_id)
        .ok_or_else(|| EditError::ClipNotFound(clip_id.to_string()))?;
    let removed = track.clips.remove(index);
    track.sort_clips();
    Ok(removed)
}

/// 적용된 커맨드 한 건(커맨드 + 그 역).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AppliedCommand {
    pub label: String,
    pub command: EditCommand,
    pub inverse: EditCommand,
}

/// undo/redo 스택.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct History {
    #[serde(default)]
    undo_stack: Vec<AppliedCommand>,
    #[serde(default)]
    redo_stack: Vec<AppliedCommand>,
    #[serde(default = "default_limit")]
    limit: usize,
}

impl Default for History {
    fn default() -> Self {
        Self::new(default_limit())
    }
}

impl History {
    pub fn new(limit: usize) -> Self {
        Self {
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            limit: limit.max(1),
        }
    }

    pub fn limit(&self) -> usize {
        self.limit
    }

    pub fn set_limit(&mut self, limit: usize) {
        self.limit = limit.max(1);
        self.trim();
    }

    fn trim(&mut self) {
        while self.undo_stack.len() > self.limit {
            self.undo_stack.remove(0);
        }
    }

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    pub fn undo_depth(&self) -> usize {
        self.undo_stack.len()
    }

    pub fn redo_depth(&self) -> usize {
        self.redo_stack.len()
    }

    pub fn undo_labels(&self) -> Vec<String> {
        self.undo_stack.iter().map(|a| a.label.clone()).collect()
    }

    pub fn peek_undo_label(&self) -> Option<&str> {
        self.undo_stack.last().map(|a| a.label.as_str())
    }

    pub fn peek_redo_label(&self) -> Option<&str> {
        self.redo_stack.last().map(|a| a.label.as_str())
    }

    pub fn clear(&mut self) {
        self.undo_stack.clear();
        self.redo_stack.clear();
    }

    /// 커맨드를 적용하고 히스토리에 쌓는다. 실패하면 히스토리는 그대로다.
    pub fn apply(
        &mut self,
        command: EditCommand,
        project: &mut Project,
    ) -> Result<AppliedCommand, EditError> {
        let label = command.label().to_string();
        let inverse = command.clone().apply(project)?;
        let applied = AppliedCommand {
            label,
            command,
            inverse,
        };
        self.undo_stack.push(applied.clone());
        self.redo_stack.clear();
        self.trim();
        Ok(applied)
    }

    /// 마지막 커맨드를 되돌린다. 되돌릴 것이 없으면 `None`.
    pub fn undo(&mut self, project: &mut Project) -> Result<Option<AppliedCommand>, EditError> {
        let Some(applied) = self.undo_stack.pop() else {
            return Ok(None);
        };
        match applied.inverse.clone().apply(project) {
            Ok(_) => {
                self.redo_stack.push(applied.clone());
                Ok(Some(applied))
            }
            Err(err) => {
                // 되돌리기 실패 시 스택을 원상복구해 일관성을 지킨다.
                self.undo_stack.push(applied);
                Err(err)
            }
        }
    }

    /// 되돌린 커맨드를 다시 적용한다.
    pub fn redo(&mut self, project: &mut Project) -> Result<Option<AppliedCommand>, EditError> {
        let Some(applied) = self.redo_stack.pop() else {
            return Ok(None);
        };
        let inverse = applied.command.clone().apply(project)?;
        let replayed = AppliedCommand {
            label: applied.label.clone(),
            command: applied.command.clone(),
            inverse,
        };
        self.undo_stack.push(replayed.clone());
        self.trim();
        Ok(Some(replayed))
    }
}

/// 적용/되돌리기 결과 요약(UI 갱신용).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CommandOutcome {
    pub label: String,
    /// "apply" | "undo" | "redo"
    pub action: String,
    pub duration_ms: i64,
    pub track_count: usize,
    pub clip_count: usize,
    pub subtitle_count: usize,
    pub can_undo: bool,
    pub can_redo: bool,
    pub undo_depth: usize,
    pub redo_depth: usize,
}

impl CommandOutcome {
    pub fn build(
        action: &str,
        label: impl Into<String>,
        project: &Project,
        history: &History,
    ) -> Self {
        Self {
            label: label.into(),
            action: action.to_string(),
            duration_ms: project.duration_ms(),
            track_count: project.tracks.len(),
            clip_count: project.tracks.iter().map(|t| t.clips.len()).sum(),
            subtitle_count: project.subtitles.items.len(),
            can_undo: history.can_undo(),
            can_redo: history.can_redo(),
            undo_depth: history.undo_depth(),
            redo_depth: history.redo_depth(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Resolution, TrackKind};

    fn project() -> Project {
        Project::blank("테스트", Resolution::VERTICAL_1080P, 30)
    }

    fn video_track(project: &Project) -> TrackId {
        project.tracks[0].id.clone()
    }

    fn new_clip(project: &mut Project, offset: i64, start: i64, end: i64) -> Clip {
        let id = project.mint_clip_id();
        let mut clip = Clip::new_media(id, ClipKind::Video, "/media/a.mp4", start, end);
        clip.timeline_offset_ms = offset;
        clip
    }

    #[test]
    fn add_and_remove_clip_are_inverse() {
        let mut p = project();
        let track = video_track(&p);
        let clip = new_clip(&mut p, 0, 0, 2_000);
        let clip_id = clip.id.clone();

        let inverse = EditCommand::AddClip {
            track_id: track.clone(),
            clip,
        }
        .apply(&mut p)
        .expect("add");
        assert_eq!(p.tracks[0].clips.len(), 1);
        assert_eq!(
            inverse,
            EditCommand::RemoveClip {
                track_id: track.clone(),
                clip_id
            }
        );

        inverse.apply(&mut p).expect("remove");
        assert_eq!(p.tracks[0].clips.len(), 0);
    }

    #[test]
    fn add_clip_rejects_overlap_and_wrong_track() {
        let mut p = project();
        let track = video_track(&p);
        EditCommand::AddClip {
            track_id: track.clone(),
            clip: new_clip(&mut p, 0, 0, 2_000),
        }
        .apply(&mut p)
        .expect("first");

        let overlapping = new_clip(&mut p, 1_000, 0, 1_000);
        let err = EditCommand::AddClip {
            track_id: track.clone(),
            clip: overlapping,
        }
        .apply(&mut p)
        .unwrap_err();
        assert!(matches!(err, EditError::Overlap { .. }));

        let audio_track = p.tracks[1].id.clone();
        let video_clip = new_clip(&mut p, 5_000, 0, 1_000);
        let err = EditCommand::AddClip {
            track_id: audio_track,
            clip: video_clip,
        }
        .apply(&mut p)
        .unwrap_err();
        assert!(matches!(err, EditError::IncompatibleTrackKind { .. }));
    }

    #[test]
    fn trim_clip_moves_in_point_and_restores() {
        let mut p = project();
        let track = video_track(&p);
        let clip = new_clip(&mut p, 0, 1_000, 5_000);
        let clip_id = clip.id.clone();
        EditCommand::AddClip {
            track_id: track.clone(),
            clip,
        }
        .apply(&mut p)
        .expect("add");

        let inverse = EditCommand::TrimClip {
            track_id: track.clone(),
            clip_id: clip_id.clone(),
            start_ms: Some(2_000),
            end_ms: Some(4_000),
            timeline_offset_ms: None,
        }
        .apply(&mut p)
        .expect("trim");

        let clip = p.tracks[0].clip(&clip_id).expect("clip");
        assert_eq!((clip.start_ms, clip.end_ms), (2_000, 4_000));
        assert_eq!(clip.timeline_duration_ms(), 2_000);

        inverse.apply(&mut p).expect("undo trim");
        let clip = p.tracks[0].clip(&clip_id).expect("clip");
        assert_eq!((clip.start_ms, clip.end_ms), (1_000, 5_000));
    }

    #[test]
    fn trim_rejects_overlap_with_neighbour() {
        let mut p = project();
        let track = video_track(&p);
        let first = new_clip(&mut p, 0, 0, 1_000);
        let first_id = first.id.clone();
        EditCommand::AddClip {
            track_id: track.clone(),
            clip: first,
        }
        .apply(&mut p)
        .expect("add first");
        let second = new_clip(&mut p, 1_000, 0, 1_000);
        EditCommand::AddClip {
            track_id: track.clone(),
            clip: second,
        }
        .apply(&mut p)
        .expect("add second");

        // 첫 클립의 끝을 늘리면 두 번째와 겹친다.
        let err = EditCommand::TrimClip {
            track_id: track,
            clip_id: first_id,
            start_ms: None,
            end_ms: Some(2_000),
            timeline_offset_ms: None,
        }
        .apply(&mut p)
        .unwrap_err();
        assert!(matches!(err, EditError::Overlap { .. }));
    }

    #[test]
    fn split_creates_two_clips_and_undo_restores() {
        let mut p = project();
        let track = video_track(&p);
        let clip = new_clip(&mut p, 0, 0, 4_000);
        let clip_id = clip.id.clone();
        EditCommand::AddClip {
            track_id: track.clone(),
            clip,
        }
        .apply(&mut p)
        .expect("add");

        let inverse = EditCommand::SplitClip {
            track_id: track.clone(),
            clip_id: clip_id.clone(),
            at_timeline_ms: 1_500,
            right_clip_id: Some(ClipId::new("clp-fixed")),
        }
        .apply(&mut p)
        .expect("split");

        let clips = &p.tracks[0].clips;
        assert_eq!(clips.len(), 2);
        assert_eq!(clips[0].id, clip_id);
        assert_eq!(clips[0].end_ms, 1_500);
        assert_eq!(clips[1].id, ClipId::new("clp-fixed"));
        assert_eq!(clips[1].start_ms, 1_500);
        assert_eq!(clips[1].timeline_offset_ms, 1_500);
        assert_eq!(p.duration_ms(), 4_000);

        inverse.apply(&mut p).expect("undo split");
        assert_eq!(p.tracks[0].clips.len(), 1);
        assert_eq!(p.tracks[0].clips[0].end_ms, 4_000);
    }

    #[test]
    fn split_respects_speed() {
        let mut p = project();
        let track = video_track(&p);
        let mut clip = new_clip(&mut p, 0, 0, 4_000);
        clip.speed = 2.0;
        let clip_id = clip.id.clone();
        EditCommand::AddClip {
            track_id: track.clone(),
            clip,
        }
        .apply(&mut p)
        .expect("add");

        EditCommand::SplitClip {
            track_id: track,
            clip_id,
            at_timeline_ms: 1_000,
            right_clip_id: None,
        }
        .apply(&mut p)
        .expect("split");

        let clips = &p.tracks[0].clips;
        assert_eq!(clips.len(), 2);
        assert_eq!(
            clips[0].end_ms, 2_000,
            "2x 속도면 1000ms 지점은 소스 2000ms"
        );
        assert_eq!(clips[1].start_ms, 2_000);
    }

    #[test]
    fn move_clip_between_tracks() {
        let mut p = project();
        let video = p.tracks[0].id.clone();
        let overlay = p.tracks[2].id.clone();
        let clip = new_clip(&mut p, 0, 0, 1_000);
        let clip_id = clip.id.clone();
        EditCommand::AddClip {
            track_id: video.clone(),
            clip,
        }
        .apply(&mut p)
        .expect("add");

        let inverse = EditCommand::MoveClip {
            track_id: video.clone(),
            clip_id: clip_id.clone(),
            to_track_id: Some(overlay.clone()),
            timeline_offset_ms: 2_000,
        }
        .apply(&mut p)
        .expect("move");

        assert_eq!(p.tracks[0].clips.len(), 0);
        assert_eq!(p.tracks[2].clips.len(), 1);
        assert_eq!(p.tracks[2].clips[0].timeline_offset_ms, 2_000);

        inverse.apply(&mut p).expect("undo move");
        assert_eq!(p.tracks[0].clips.len(), 1);
        assert_eq!(p.tracks[2].clips.len(), 0);
        assert_eq!(p.tracks[0].clips[0].timeline_offset_ms, 0);
    }

    #[test]
    fn speed_volume_and_fades_roundtrip() {
        let mut p = project();
        let track = video_track(&p);
        let clip = new_clip(&mut p, 0, 0, 2_000);
        let clip_id = clip.id.clone();
        EditCommand::AddClip {
            track_id: track.clone(),
            clip,
        }
        .apply(&mut p)
        .expect("add");

        let inv_speed = EditCommand::SetClipSpeed {
            track_id: track.clone(),
            clip_id: clip_id.clone(),
            speed: 1.5,
        }
        .apply(&mut p)
        .expect("speed");
        assert_eq!(p.tracks[0].clip(&clip_id).unwrap().speed, 1.5);
        inv_speed.apply(&mut p).expect("undo speed");
        assert_eq!(p.tracks[0].clip(&clip_id).unwrap().speed, 1.0);

        let inv_fade = EditCommand::SetClipFades {
            track_id: track.clone(),
            clip_id: clip_id.clone(),
            fade_in_ms: 300,
            fade_out_ms: 400,
        }
        .apply(&mut p)
        .expect("fade");
        assert_eq!(p.tracks[0].clip(&clip_id).unwrap().fade_in_ms, 300);
        inv_fade.apply(&mut p).expect("undo fade");
        assert_eq!(p.tracks[0].clip(&clip_id).unwrap().fade_in_ms, 0);

        let err = EditCommand::SetClipVolume {
            track_id: track,
            clip_id,
            volume: 5.0,
        }
        .apply(&mut p)
        .unwrap_err();
        assert!(matches!(err, EditError::OutOfRange { .. }));
    }

    #[test]
    fn locked_track_refuses_edits() {
        let mut p = project();
        let track = video_track(&p);
        EditCommand::SetTrackState {
            track_id: track.clone(),
            muted: None,
            hidden: None,
            locked: Some(true),
        }
        .apply(&mut p)
        .expect("lock");

        let err = EditCommand::AddClip {
            track_id: track,
            clip: new_clip(&mut p, 0, 0, 1_000),
        }
        .apply(&mut p)
        .unwrap_err();
        assert!(matches!(err, EditError::TrackLocked(_)));
    }

    #[test]
    fn subtitles_add_update_remove() {
        let mut p = project();
        let id = p.mint_subtitle_id();
        let item = SubtitleItem::new(id.clone(), 500, 2_000, "안녕하세요");

        let inv = EditCommand::AddSubtitle { item }
            .apply(&mut p)
            .expect("add subtitle");
        assert_eq!(p.subtitles.items.len(), 1);
        assert_eq!(
            p.subtitles.text_at(1_000),
            Some("안녕하세요"),
            "자막이 시간에 맞게 조회된다"
        );

        let patch = SubtitlePatch {
            text: Some("반갑습니다".into()),
            ..Default::default()
        };
        let inv_update = EditCommand::UpdateSubtitle {
            id: id.clone(),
            patch,
        }
        .apply(&mut p)
        .expect("update");
        assert_eq!(p.subtitles.text_at(1_000), Some("반갑습니다"));

        inv_update.apply(&mut p).expect("undo update");
        assert_eq!(p.subtitles.text_at(1_000), Some("안녕하세요"));

        inv.apply(&mut p).expect("undo add");
        assert_eq!(p.subtitles.items.len(), 0);
    }

    #[test]
    fn subtitle_overlap_is_rejected() {
        let mut p = project();
        let first = SubtitleItem::new(p.mint_subtitle_id(), 0, 1_000, "하나");
        EditCommand::AddSubtitle { item: first }
            .apply(&mut p)
            .expect("first");

        let second = SubtitleItem::new(p.mint_subtitle_id(), 500, 1_500, "둘");
        let err = EditCommand::AddSubtitle { item: second }
            .apply(&mut p)
            .unwrap_err();
        assert!(matches!(err, EditError::Overlap { .. }));
    }

    #[test]
    fn history_undo_redo_cycle_is_consistent() {
        let mut p = project();
        let mut history = History::default();
        let track = video_track(&p);

        history
            .apply(
                EditCommand::AddClip {
                    track_id: track.clone(),
                    clip: new_clip(&mut p, 0, 0, 1_000),
                },
                &mut p,
            )
            .expect("add 1");
        history
            .apply(
                EditCommand::AddClip {
                    track_id: track.clone(),
                    clip: new_clip(&mut p, 1_000, 0, 1_000),
                },
                &mut p,
            )
            .expect("add 2");
        assert_eq!(p.tracks[0].clips.len(), 2);
        assert_eq!(history.undo_depth(), 2);

        history.undo(&mut p).expect("undo").expect("some");
        assert_eq!(p.tracks[0].clips.len(), 1);
        assert_eq!(history.redo_depth(), 1);

        history.redo(&mut p).expect("redo").expect("some");
        assert_eq!(p.tracks[0].clips.len(), 2);
        assert_eq!(history.redo_depth(), 0);

        // 새 편집을 하면 redo 스택은 비워진다.
        history.undo(&mut p).expect("undo");
        history
            .apply(
                EditCommand::AddClip {
                    track_id: track,
                    clip: new_clip(&mut p, 5_000, 0, 500),
                },
                &mut p,
            )
            .expect("new edit");
        assert!(!history.can_redo());
    }

    #[test]
    fn history_limit_drops_oldest() {
        let mut p = project();
        let mut history = History::new(3);
        let track = video_track(&p);
        for i in 0..5 {
            let offset = i * 100;
            history
                .apply(
                    EditCommand::AddClip {
                        track_id: track.clone(),
                        clip: new_clip(&mut p, offset, 0, 100),
                    },
                    &mut p,
                )
                .expect("add");
        }
        assert_eq!(history.undo_depth(), 3);
        // 가장 오래된 두 개는 버려져서 3번만 되돌릴 수 있다.
        for _ in 0..3 {
            history.undo(&mut p).expect("undo").expect("some");
        }
        assert_eq!(history.undo(&mut p).expect("undo"), None);
        assert_eq!(p.tracks[0].clips.len(), 2);
    }

    #[test]
    fn batch_is_atomic() {
        let mut p = project();
        let track = video_track(&p);
        let first = new_clip(&mut p, 0, 0, 1_000);
        let second = new_clip(&mut p, 500, 0, 1_000); // 첫 클립과 겹친다
        let err = EditCommand::Batch {
            commands: vec![
                EditCommand::AddClip {
                    track_id: track.clone(),
                    clip: first,
                },
                EditCommand::AddClip {
                    track_id: track,
                    clip: second,
                },
            ],
        }
        .apply(&mut p)
        .unwrap_err();
        assert!(matches!(err, EditError::Overlap { .. }));
        assert_eq!(
            p.tracks[0].clips.len(),
            0,
            "실패한 배치는 아무것도 남기지 않는다"
        );
    }

    #[test]
    fn text_clip_needs_content() {
        let mut p = project();
        let overlay = p.tracks[2].id.clone();
        let mut empty = TextOverlay::new("");
        empty.content = "  ".into();
        let id = p.mint_clip_id();
        let clip = Clip::new_text(id, empty, 1_000);
        let err = EditCommand::AddClip {
            track_id: overlay,
            clip,
        }
        .apply(&mut p)
        .unwrap_err();
        assert_eq!(err, EditError::EmptyText);
    }

    #[test]
    fn add_track_and_remove_track_roundtrip() {
        let mut p = project();
        let id = p.mint_track_id();
        let track = Track::new(id.clone(), "Overlay 2", TrackKind::Overlay);
        let inverse = EditCommand::AddTrack { track }
            .apply(&mut p)
            .expect("add track");
        assert_eq!(p.tracks.len(), 4);
        inverse.apply(&mut p).expect("remove track");
        assert_eq!(p.tracks.len(), 3);
    }
}
