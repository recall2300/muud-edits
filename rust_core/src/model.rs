//! 프로젝트 데이터 모델.
//!
//! 시간 단위는 전부 **정수 밀리초(i64)** 다. 초 단위 부동소수는 누적 오차와
//! 프레임 경계 문제를 만들기 때문에, 타임라인은 ms로 저장하고 화면에 그릴 때만
//! [`crate::timeline::snap_to_frame`]으로 프레임에 맞춘다.
//!
//! ## 불변식
//! * `0 <= start_ms < end_ms` (소스 구간)
//! * `timeline_offset_ms >= 0`
//! * `MIN_SPEED <= speed <= MAX_SPEED`, `0.0 <= volume <= MAX_VOLUME`
//! * 같은 트랙의 클립은 겹치지 않는다 (오버레이 성격의 트랙 제외 — [`Track::allow_overlap`])
//! * 클립 종류는 트랙 종류와 맞아야 한다 ([`TrackKind::accepts`])

use serde::{Deserialize, Serialize};

use crate::error::EditError;
use crate::export::ExportSettings;
use crate::ids::{ClipId, IdSeq, SubtitleId, TrackId};
use crate::subtitles::SubtitleTrack;
use crate::timeline;

/// 허용되는 최소 재생 속도(0.25x 슬로모션).
pub const MIN_SPEED: f32 = 0.25;
/// 허용되는 최대 재생 속도(4x 배속).
pub const MAX_SPEED: f32 = 4.0;
/// 볼륨 상한(선형 게인, +6dB).
pub const MAX_VOLUME: f32 = 2.0;

fn default_schema_version() -> u32 {
    crate::project_io::SCHEMA_VERSION
}
fn default_fps() -> u32 {
    30
}
fn default_sample_rate() -> u32 {
    48_000
}
fn default_one() -> f32 {
    1.0
}
fn default_font_family() -> String {
    "Pretendard".to_string()
}
fn default_font_size() -> f32 {
    64.0
}
fn default_text_color() -> String {
    "#FFFFFFFF".to_string()
}

/// 출력 해상도.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Resolution {
    pub width: u32,
    pub height: u32,
}

impl Resolution {
    /// 숏폼 기본값: 1080x1920 (9:16).
    pub const VERTICAL_1080P: Resolution = Resolution {
        width: 1080,
        height: 1920,
    };
    /// 가로 기본값: 1920x1080 (16:9).
    pub const LANDSCAPE_1080P: Resolution = Resolution {
        width: 1920,
        height: 1080,
    };

    pub const fn new(width: u32, height: u32) -> Self {
        Self { width, height }
    }

    pub fn is_even(&self) -> bool {
        self.width % 2 == 0 && self.height % 2 == 0
    }

    pub fn aspect_ratio(&self) -> f64 {
        if self.height == 0 {
            0.0
        } else {
            f64::from(self.width) / f64::from(self.height)
        }
    }

    pub fn is_portrait(&self) -> bool {
        self.height > self.width
    }

    /// `max` 안에 비율을 유지한 채 들어가는 크기(짝수로 내림).
    pub fn fit_within(&self, max: Resolution) -> Resolution {
        if self.width == 0 || self.height == 0 {
            return max;
        }
        let scale = (f64::from(max.width) / f64::from(self.width))
            .min(f64::from(max.height) / f64::from(self.height));
        let w = ((f64::from(self.width) * scale).round() as u32).max(2) & !1;
        let h = ((f64::from(self.height) * scale).round() as u32).max(2) & !1;
        Resolution::new(w, h)
    }

    pub fn pixels(&self) -> u64 {
        u64::from(self.width) * u64::from(self.height)
    }
}

impl Default for Resolution {
    fn default() -> Self {
        Self::VERTICAL_1080P
    }
}

/// 트랙 종류.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackKind {
    /// 영상/이미지 레이어.
    Video,
    /// 오디오 레이어.
    Audio,
    /// 오버레이(텍스트·스티커) 레이어. 겹침을 허용한다.
    Overlay,
}

impl TrackKind {
    /// 이 트랙에 해당 클립 종류를 올릴 수 있는가.
    pub fn accepts(self, clip: ClipKind) -> bool {
        match (self, clip) {
            (TrackKind::Video, ClipKind::Video | ClipKind::Image) => true,
            (TrackKind::Audio, ClipKind::Audio) => true,
            (TrackKind::Overlay, ClipKind::Text | ClipKind::Image | ClipKind::Video) => true,
            _ => false,
        }
    }

    /// 같은 트랙 안에서 클립 겹침을 허용하는가.
    pub fn allows_overlap(self) -> bool {
        matches!(self, TrackKind::Overlay)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            TrackKind::Video => "video",
            TrackKind::Audio => "audio",
            TrackKind::Overlay => "overlay",
        }
    }
}

/// 클립 종류.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClipKind {
    /// 비디오 파일.
    Video,
    /// 오디오 파일.
    Audio,
    /// 정지 이미지(길이를 늘려도 정지).
    Image,
    /// 파일 없이 텍스트만 그리는 클립.
    Text,
}

impl ClipKind {
    pub fn is_media(self) -> bool {
        matches!(self, ClipKind::Video | ClipKind::Audio | ClipKind::Image)
    }

    pub fn is_visual(self) -> bool {
        !matches!(self, ClipKind::Audio)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            ClipKind::Video => "video",
            ClipKind::Audio => "audio",
            ClipKind::Image => "image",
            ClipKind::Text => "text",
        }
    }
}

/// 텍스트 정렬.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TextAlign {
    Start,
    #[default]
    Center,
    End,
}

/// 정규화 좌표(0.0~1.0). (0,0)=좌상단, (1,1)=우하단.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct NormalizedAnchor {
    pub x: f32,
    pub y: f32,
}

impl Default for NormalizedAnchor {
    fn default() -> Self {
        // 숏폼 자막이 놓이는 흔한 위치(아래쪽 1/6 지점).
        Self { x: 0.5, y: 0.82 }
    }
}

impl NormalizedAnchor {
    pub fn new(x: f32, y: f32) -> Self {
        Self {
            x: x.clamp(0.0, 1.0),
            y: y.clamp(0.0, 1.0),
        }
    }
}

/// 클립에 실리는 텍스트 스타일.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextOverlay {
    pub content: String,
    #[serde(default = "default_font_family")]
    pub font_family: String,
    #[serde(default = "default_font_size")]
    pub size_px: f32,
    #[serde(default = "default_text_color")]
    pub color: String,
    #[serde(default)]
    pub background: Option<String>,
    #[serde(default)]
    pub stroke_px: f32,
    #[serde(default)]
    pub align: TextAlign,
    #[serde(default)]
    pub anchor: NormalizedAnchor,
}

impl TextOverlay {
    pub fn new(content: impl Into<String>) -> Self {
        Self {
            content: content.into(),
            font_family: default_font_family(),
            size_px: default_font_size(),
            color: default_text_color(),
            background: None,
            stroke_px: 0.0,
            align: TextAlign::Center,
            anchor: NormalizedAnchor::default(),
        }
    }
}

/// 타임라인 위의 클립 하나.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Clip {
    pub id: ClipId,
    /// 원본 미디어 경로. `ClipKind::Text`면 빈 문자열.
    #[serde(default)]
    pub source_path: String,
    #[serde(default = "default_clip_kind")]
    pub kind: ClipKind,
    /// 소스 인점(포함).
    pub start_ms: i64,
    /// 소스 아웃점(제외).
    pub end_ms: i64,
    /// 타임라인에서 이 클립이 시작하는 위치.
    #[serde(default)]
    pub timeline_offset_ms: i64,
    #[serde(default = "default_one")]
    pub speed: f32,
    #[serde(default = "default_one")]
    pub volume: f32,
    #[serde(default = "default_one")]
    pub opacity: f32,
    #[serde(default)]
    pub fade_in_ms: u32,
    #[serde(default)]
    pub fade_out_ms: u32,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub text: Option<TextOverlay>,
    /// 프로브로 알아낸 소스 전체 길이(검증용, 선택).
    #[serde(default)]
    pub source_duration_ms: Option<i64>,
}

fn default_clip_kind() -> ClipKind {
    ClipKind::Video
}
fn default_true() -> bool {
    true
}

impl Clip {
    /// 미디어 클립 생성. 길이 검증은 커맨드에서 한다.
    pub fn new_media(
        id: ClipId,
        kind: ClipKind,
        source_path: impl Into<String>,
        start_ms: i64,
        end_ms: i64,
    ) -> Self {
        Self {
            id,
            source_path: source_path.into(),
            kind,
            start_ms,
            end_ms,
            timeline_offset_ms: 0,
            speed: 1.0,
            volume: 1.0,
            opacity: 1.0,
            fade_in_ms: 0,
            fade_out_ms: 0,
            enabled: true,
            text: None,
            source_duration_ms: None,
        }
    }

    /// 텍스트 클립 생성. `duration_ms`는 타임라인 표시 길이.
    pub fn new_text(id: ClipId, text: TextOverlay, duration_ms: i64) -> Self {
        Self {
            id,
            source_path: String::new(),
            kind: ClipKind::Text,
            start_ms: 0,
            end_ms: duration_ms.max(1),
            timeline_offset_ms: 0,
            speed: 1.0,
            volume: 0.0,
            opacity: 1.0,
            fade_in_ms: 0,
            fade_out_ms: 0,
            enabled: true,
            text: Some(text),
            source_duration_ms: None,
        }
    }

    /// 소스로부터 사용하는 길이(ms).
    pub fn source_span_ms(&self) -> i64 {
        self.end_ms - self.start_ms
    }

    /// 재생 속도를 반영한 타임라인 점유 길이(ms). 최소 1ms.
    pub fn timeline_duration_ms(&self) -> i64 {
        let speed = if self.speed.is_finite() && self.speed > 0.0 {
            self.speed
        } else {
            1.0
        };
        ((self.source_span_ms() as f64) / f64::from(speed)).round() as i64
    }

    /// 타임라인에서 이 클립이 끝나는 지점(제외).
    pub fn timeline_end_ms(&self) -> i64 {
        self.timeline_offset_ms + self.timeline_duration_ms()
    }

    /// 타임라인 시각 → 소스 시각.
    pub fn source_time_at(&self, timeline_ms: i64) -> i64 {
        let delta = (timeline_ms - self.timeline_offset_ms).max(0);
        let scaled = (delta as f64 * f64::from(self.speed)).round() as i64;
        (self.start_ms + scaled).min(self.end_ms)
    }

    /// 소스 시각 → 타임라인 시각.
    pub fn timeline_time_of(&self, source_ms: i64) -> i64 {
        let delta = (source_ms - self.start_ms).max(0);
        let scaled = (delta as f64 / f64::from(self.speed.max(0.001))).round() as i64;
        self.timeline_offset_ms + scaled
    }

    /// 해당 타임라인 시각에 포함되는가(끝점 제외).
    pub fn contains(&self, timeline_ms: i64) -> bool {
        timeline_ms >= self.timeline_offset_ms && timeline_ms < self.timeline_end_ms()
    }

    /// 페이드 인/아웃을 반영한 게인(0.0~1.0).
    pub fn gain_at(&self, timeline_ms: i64) -> f32 {
        let local = timeline_ms - self.timeline_offset_ms;
        let duration = self.timeline_duration_ms();
        let mut gain = 1.0f32;
        if self.fade_in_ms > 0 && local < i64::from(self.fade_in_ms) {
            gain = gain.min((local.max(0) as f32) / (self.fade_in_ms.max(1) as f32));
        }
        if self.fade_out_ms > 0 {
            let remaining = duration - local;
            if remaining < i64::from(self.fade_out_ms) {
                gain = gain.min((remaining.max(0) as f32) / (self.fade_out_ms.max(1) as f32));
            }
        }
        gain.clamp(0.0, 1.0)
    }

    /// 이 클립이 차지하는 타임라인 구간이 `[start, end)`와 겹치는가.
    pub fn overlaps(&self, start: i64, end: i64) -> bool {
        self.timeline_offset_ms < end && start < self.timeline_end_ms()
    }

    /// 기본적인 필드 검증. 커맨드가 변이 전에 호출한다.
    pub fn validate(&self) -> Result<(), EditError> {
        if self.start_ms < 0 || self.end_ms < 0 || self.timeline_offset_ms < 0 {
            return Err(EditError::NegativeTime {
                value: self.start_ms.min(self.end_ms).min(self.timeline_offset_ms),
            });
        }
        if self.start_ms >= self.end_ms {
            return Err(EditError::InvalidTimeRange {
                start: self.start_ms,
                end: self.end_ms,
            });
        }
        if !(MIN_SPEED..=MAX_SPEED).contains(&self.speed) {
            return Err(EditError::OutOfRange {
                field: "speed".into(),
                value: format!("{}", self.speed),
            });
        }
        if !(0.0..=MAX_VOLUME).contains(&self.volume) {
            return Err(EditError::OutOfRange {
                field: "volume".into(),
                value: format!("{}", self.volume),
            });
        }
        if !(0.0..=1.0).contains(&self.opacity) {
            return Err(EditError::OutOfRange {
                field: "opacity".into(),
                value: format!("{}", self.opacity),
            });
        }
        if let (Some(limit), true) = (self.source_duration_ms, self.end_ms > 0) {
            if self.end_ms > limit {
                return Err(EditError::SourceOverflow {
                    limit,
                    value: self.end_ms,
                });
            }
        }
        if self.kind == ClipKind::Text {
            let Some(text) = &self.text else {
                return Err(EditError::Unsupported("text 클립에는 텍스트가 필요합니다"));
            };
            if text.content.trim().is_empty() {
                return Err(EditError::EmptyText);
            }
        } else if self.source_path.trim().is_empty() {
            return Err(EditError::Invalid(
                "미디어 클립에 소스 경로가 없습니다".into(),
            ));
        }
        Ok(())
    }
}

/// 타임라인 트랙 하나.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Track {
    pub id: TrackId,
    pub name: String,
    pub kind: TrackKind,
    #[serde(default)]
    pub clips: Vec<Clip>,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub locked: bool,
    /// 오디오 선형 게인(1.0 = 원본).
    #[serde(default = "default_one")]
    pub gain: f32,
}

impl Track {
    pub fn new(id: TrackId, name: impl Into<String>, kind: TrackKind) -> Self {
        Self {
            id,
            name: name.into(),
            kind,
            clips: Vec::new(),
            muted: false,
            hidden: false,
            locked: false,
            gain: 1.0,
        }
    }

    pub fn clip(&self, id: &ClipId) -> Option<&Clip> {
        self.clips.iter().find(|c| &c.id == id)
    }

    pub fn clip_index(&self, id: &ClipId) -> Option<usize> {
        self.clips.iter().position(|c| &c.id == id)
    }

    /// 타임라인 오프셋 기준으로 정렬. 편집 후 항상 호출한다.
    pub fn sort_clips(&mut self) {
        self.clips
            .sort_by(|a, b| a.timeline_offset_ms.cmp(&b.timeline_offset_ms));
    }

    pub fn duration_ms(&self) -> i64 {
        self.clips
            .iter()
            .map(Clip::timeline_end_ms)
            .max()
            .unwrap_or(0)
    }

    /// 클립을 놓을 자리를 비워 둔 마지막 지점(이어붙이기 기본값).
    pub fn append_offset_ms(&self) -> i64 {
        self.duration_ms()
    }

    /// `ignore`를 제외하고 `[start, end)`와 겹치는 클립.
    pub fn overlapping_clip(&self, start: i64, end: i64, ignore: Option<&ClipId>) -> Option<&Clip> {
        self.clips
            .iter()
            .filter(|c| Some(&c.id) != ignore)
            .find(|c| c.overlaps(start, end))
    }

    /// 이 트랙에 클립을 놓을 수 있는지 검사(겹침 포함).
    pub fn check_placement(
        &self,
        start: i64,
        end: i64,
        ignore: Option<&ClipId>,
    ) -> Result<(), EditError> {
        if end <= start {
            return Err(EditError::InvalidTimeRange { start, end });
        }
        if start < 0 {
            return Err(EditError::NegativeTime { value: start });
        }
        if self.kind.allows_overlap() {
            return Ok(());
        }
        if let Some(other) = self.overlapping_clip(start, end, ignore) {
            return Err(EditError::Overlap {
                track: self.id.to_string(),
                other: other.id.to_string(),
            });
        }
        Ok(())
    }
}

/// 재생 헤드 위치에서 실제로 그려지는 레이어.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ActiveLayer {
    pub track_id: TrackId,
    pub track_kind: TrackKind,
    pub clip_id: ClipId,
    pub clip_kind: ClipKind,
    pub opacity: f32,
    pub gain: f32,
    /// 클립 안에서의 재생 위치(ms).
    pub clip_time_ms: i64,
    /// 해당 위치의 소스 시각(ms).
    pub source_time_ms: i64,
    #[serde(default)]
    pub text: Option<TextOverlay>,
}

/// 편집 프로젝트 전체.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Project {
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub created_at_ms: i64,
    #[serde(default)]
    pub modified_at_ms: i64,
    #[serde(default)]
    pub resolution: Resolution,
    #[serde(default = "default_fps")]
    pub fps: u32,
    #[serde(default = "default_sample_rate")]
    pub sample_rate: u32,
    #[serde(default)]
    pub tracks: Vec<Track>,
    #[serde(default)]
    pub subtitles: SubtitleTrack,
    #[serde(default)]
    pub export: ExportSettings,
    #[serde(default)]
    pub ids: IdSeq,
}

impl Project {
    /// 트랙이 없는 빈 프로젝트.
    pub fn empty(name: impl Into<String>, resolution: Resolution, fps: u32) -> Self {
        let now = crate::now_ms();
        Self {
            schema_version: crate::project_io::SCHEMA_VERSION,
            id: format!("prj-{now}"),
            name: name.into(),
            created_at_ms: now,
            modified_at_ms: now,
            resolution,
            fps: fps.max(1),
            sample_rate: default_sample_rate(),
            tracks: Vec::new(),
            subtitles: SubtitleTrack::default(),
            export: ExportSettings::for_project(resolution, fps),
            ids: IdSeq::default(),
        }
    }

    /// 숏폼 기본 구성: Video 1 / Audio 1 / Overlay 1.
    pub fn blank(name: impl Into<String>, resolution: Resolution, fps: u32) -> Self {
        let mut project = Self::empty(name, resolution, fps);
        let video = project.mint_track_id();
        project
            .tracks
            .push(Track::new(video, "Video 1", TrackKind::Video));
        let audio = project.mint_track_id();
        project
            .tracks
            .push(Track::new(audio, "Audio 1", TrackKind::Audio));
        let overlay = project.mint_track_id();
        project
            .tracks
            .push(Track::new(overlay, "Overlay 1", TrackKind::Overlay));
        project
    }

    pub fn mint_track_id(&mut self) -> TrackId {
        self.ids.mint_track()
    }

    pub fn mint_clip_id(&mut self) -> ClipId {
        self.ids.mint_clip()
    }

    pub fn mint_subtitle_id(&mut self) -> SubtitleId {
        self.ids.mint_subtitle()
    }

    /// 마지막 수정 시각을 갱신한다.
    pub fn touch(&mut self) {
        self.modified_at_ms = crate::now_ms();
    }

    pub fn track(&self, id: &TrackId) -> Option<&Track> {
        self.tracks.iter().find(|t| &t.id == id)
    }

    pub fn track_mut(&mut self, id: &TrackId) -> Option<&mut Track> {
        self.tracks.iter_mut().find(|t| &t.id == id)
    }

    pub fn track_index(&self, id: &TrackId) -> Option<usize> {
        self.tracks.iter().position(|t| &t.id == id)
    }

    fn require_track(&self, id: &TrackId) -> Result<&Track, EditError> {
        self.track(id)
            .ok_or_else(|| EditError::TrackNotFound(id.to_string()))
    }

    fn require_track_mut(&mut self, id: &TrackId) -> Result<&mut Track, EditError> {
        self.track_mut(id)
            .ok_or_else(|| EditError::TrackNotFound(id.to_string()))
    }

    pub fn clip(&self, track_id: &TrackId, clip_id: &ClipId) -> Option<&Clip> {
        self.track(track_id).and_then(|t| t.clip(clip_id))
    }

    /// 프로젝트 어디에 있든 클립과 그 트랙을 찾는다.
    pub fn find_clip(&self, clip_id: &ClipId) -> Option<(&Track, &Clip)> {
        self.tracks
            .iter()
            .find_map(|t| t.clip(clip_id).map(|c| (t, c)))
    }

    /// 전체 타임라인 길이(자막 포함).
    pub fn duration_ms(&self) -> i64 {
        let tracks = self
            .tracks
            .iter()
            .map(Track::duration_ms)
            .max()
            .unwrap_or(0);
        tracks.max(self.subtitles.duration_ms())
    }

    /// 이 트랙 종류에서 다음에 쓸 수 있는 트랙 이름.
    pub fn unique_track_name(&self, kind: TrackKind) -> String {
        let base = match kind {
            TrackKind::Video => "Video",
            TrackKind::Audio => "Audio",
            TrackKind::Overlay => "Overlay",
        };
        let mut n = self.tracks.iter().filter(|t| t.kind == kind).count() + 1;
        loop {
            let candidate = format!("{base} {n}");
            if !self.tracks.iter().any(|t| t.name == candidate) {
                return candidate;
            }
            n += 1;
        }
    }

    /// 재생 헤드 `at_ms`에서 그려야 하는 레이어 목록(아래 → 위 순서).
    pub fn layers_at(&self, at_ms: i64) -> Vec<ActiveLayer> {
        let mut layers = Vec::new();
        for track in &self.tracks {
            if track.hidden || track.muted && track.kind == TrackKind::Audio {
                continue;
            }
            for clip in &track.clips {
                if !clip.enabled || !clip.contains(at_ms) {
                    continue;
                }
                layers.push(ActiveLayer {
                    track_id: track.id.clone(),
                    track_kind: track.kind,
                    clip_id: clip.id.clone(),
                    clip_kind: clip.kind,
                    opacity: clip.opacity * clip.gain_at(at_ms),
                    gain: track.gain * clip.volume * clip.gain_at(at_ms),
                    clip_time_ms: at_ms - clip.timeline_offset_ms,
                    source_time_ms: clip.source_time_at(at_ms),
                    text: clip.text.clone(),
                });
            }
        }
        layers
    }

    /// 타임라인 불변식 점검. 저장 직전/불러온 직후에 쓴다.
    pub fn validate(&self) -> Vec<String> {
        let mut issues = Vec::new();
        if self.fps == 0 {
            issues.push("fps가 0입니다".to_string());
        }
        if self.resolution.width == 0 || self.resolution.height == 0 {
            issues.push("해상도가 0입니다".to_string());
        }
        for track in &self.tracks {
            for clip in &track.clips {
                if let Err(err) = clip.validate() {
                    issues.push(format!("{}/{}: {err}", track.id, clip.id));
                }
                if !track.kind.accepts(clip.kind) {
                    issues.push(format!(
                        "{}/{}: {} 클립을 {} 트랙에서 사용",
                        track.id,
                        clip.id,
                        clip.kind.as_str(),
                        track.kind.as_str()
                    ));
                }
            }
            if !track.kind.allows_overlap() {
                let mut sorted: Vec<&Clip> = track.clips.iter().collect();
                sorted.sort_by_key(|c| c.timeline_offset_ms);
                for pair in sorted.windows(2) {
                    if pair[0].timeline_end_ms() > pair[1].timeline_offset_ms {
                        issues.push(format!(
                            "{}: {} 와 {} 가 겹칩니다",
                            track.id, pair[0].id, pair[1].id
                        ));
                    }
                }
            }
        }
        issues
    }

    /// 트랙 접근 헬퍼(커맨드 전용, 없으면 오류).
    pub(crate) fn track_checked(&self, id: &TrackId) -> Result<&Track, EditError> {
        self.require_track(id)
    }

    /// 잠금 검사 후 가변 트랙을 돌려준다.
    pub(crate) fn track_editable(&mut self, id: &TrackId) -> Result<&mut Track, EditError> {
        let track = self.require_track(id)?;
        if track.locked {
            return Err(EditError::TrackLocked(id.to_string()));
        }
        self.require_track_mut(id)
    }

    /// 자막 트랙을 참조로 노출(편의).
    pub fn subtitle_count(&self) -> usize {
        self.subtitles.items.len()
    }

    /// 사람이 읽는 요약 문자열(로그/디버깅).
    pub fn summary(&self) -> String {
        format!(
            "{} | {}x{} @{}fps | {} tracks | {} clips | duration {}",
            self.name,
            self.resolution.width,
            self.resolution.height,
            self.fps,
            self.tracks.len(),
            self.tracks.iter().map(|t| t.clips.len()).sum::<usize>(),
            timeline::format_timecode(self.duration_ms(), self.fps)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ids::IdSeq;

    fn sample_clip(offset: i64, start: i64, end: i64) -> Clip {
        let mut ids = IdSeq::default();
        let mut clip = Clip::new_media(ids.mint_clip(), ClipKind::Video, "/tmp/a.mp4", start, end);
        clip.timeline_offset_ms = offset;
        clip
    }

    #[test]
    fn speed_scales_timeline_duration() {
        let mut clip = sample_clip(0, 0, 4000);
        assert_eq!(clip.timeline_duration_ms(), 4000);
        clip.speed = 2.0;
        assert_eq!(clip.timeline_duration_ms(), 2000);
        clip.speed = 0.5;
        assert_eq!(clip.timeline_duration_ms(), 8000);
    }

    #[test]
    fn source_and_timeline_time_roundtrip() {
        let mut clip = sample_clip(1000, 2000, 10_000);
        clip.speed = 2.0;
        // 타임라인 1000ms 지점 = 클립 시작 = 소스 2000ms
        assert_eq!(clip.source_time_at(1000), 2000);
        // 타임라인 2000ms 지점은 클립 내부 1000ms → 소스 2000 + 2000 = 4000
        assert_eq!(clip.source_time_at(2000), 4000);
        assert_eq!(clip.timeline_time_of(4000), 2000);
    }

    #[test]
    fn fade_gain_ramps() {
        let mut clip = sample_clip(0, 0, 2000);
        clip.fade_in_ms = 500;
        clip.fade_out_ms = 500;
        assert_eq!(clip.gain_at(0), 0.0);
        assert!((clip.gain_at(250) - 0.5).abs() < 0.01);
        assert_eq!(clip.gain_at(1000), 1.0);
        assert!((clip.gain_at(1750) - 0.5).abs() < 0.01);
        assert_eq!(clip.gain_at(2000), 0.0);
    }

    #[test]
    fn validate_catches_bad_ranges() {
        let clip = sample_clip(0, 500, 500);
        assert_eq!(
            clip.validate(),
            Err(EditError::InvalidTimeRange {
                start: 500,
                end: 500
            })
        );
    }

    #[test]
    fn track_placement_rejects_overlap() {
        let mut track = Track::new(TrackId::new("trk-0001"), "V1", TrackKind::Video);
        track.clips.push(sample_clip(0, 0, 1000));
        assert!(track.check_placement(1000, 2000, None).is_ok());
        assert_eq!(
            track.check_placement(500, 1500, None),
            Err(EditError::Overlap {
                track: "trk-0001".into(),
                other: "clp-0001".into()
            })
        );
    }

    #[test]
    fn overlay_tracks_allow_overlap() {
        let mut track = Track::new(TrackId::new("trk-0002"), "O1", TrackKind::Overlay);
        track.clips.push(sample_clip(0, 0, 1000));
        assert!(track.check_placement(500, 1500, None).is_ok());
    }

    #[test]
    fn resolution_fit_keeps_even_dimensions() {
        let fitted = Resolution::new(1080, 1920).fit_within(Resolution::new(720, 720));
        assert_eq!(fitted.width % 2, 0);
        assert_eq!(fitted.height % 2, 0);
        assert_eq!(fitted, Resolution::new(404, 720));
    }

    #[test]
    fn layers_at_returns_active_clips() {
        let mut project = Project::blank("t", Resolution::VERTICAL_1080P, 30);
        let video = project.tracks[0].id.clone();
        let mut clip = sample_clip(0, 0, 1000);
        clip.id = project.mint_clip_id();
        project.tracks[0].clips.push(clip);
        assert_eq!(project.layers_at(500).len(), 1);
        assert_eq!(project.layers_at(1000).len(), 0);
        assert_eq!(project.tracks[0].id, video);
    }

    #[test]
    fn project_summary_is_readable() {
        let project = Project::blank("demo", Resolution::VERTICAL_1080P, 30);
        let s = project.summary();
        assert!(s.contains("1080x1920"));
        assert!(s.contains("3 tracks"));
        assert!(project.validate().is_empty());
    }
}
