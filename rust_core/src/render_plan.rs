//! 타임라인 → **결정적 렌더 그래프** 컴파일.
//!
//! ## 왜 필요한가
//! Rust 코어는 인코딩을 직접 하지 않는다. 대신 편집 상태(프로젝트)를
//! "렌더러가 그대로 소비할 수 있는 계획"으로 컴파일한다. 이 계획이
//! [`RenderGraph`]다.
//!
//! * 4개 플랫폼(macOS/iOS AVFoundation, Android MediaCodec, Windows MediaFoundation)
//!   구현체는 **같은 그래프를 받아** 같은 프레임을 만든다.
//! * 그래프는 순수 함수의 결과다. 같은 프로젝트 + 같은 설정 + 같은 플랫폼이면
//!   언제나 바이트 단위로 같은 JSON(`graph_digest` 포함)이 나온다.
//!   → 플랫폼 간 결과 비교, 회귀 테스트, 캐시 키로 쓸 수 있다.
//!
//! ## 시간 규칙
//! * 입력/출력 모두 정수 ms.
//! * `timeline_*`은 프로젝트 타임라인의 절대 시각, `render_*`는 **출력 파일 안에서의**
//!   시각이다(내보내기 구간이 있으면 `range.start_ms`만큼 당겨진다).
//! * 프레임 경계는 `round(ms * fps / 1000)`으로 계산한다. 반올림 규칙을 한 곳에
//!   고정해 두어야 플랫폼별 반올림 차이로 1프레임이 어긋나지 않는다.
//!
//! ## 합성 규칙(렌더러 계약)
//! * [`RenderSegment::layer`]가 작을수록 아래, 클수록 위에 그린다(트랙 선언 순서).
//! * 투명도는 `opacity_curve`를 `render_start_ms`부터 선형 보간해 적용한다.
//! * 오디오는 [`AudioMixSegment`]를 **모두 더한다**(크로스페이드는 `gain_curve`가 담당).
//! * 자막은 [`SubtitleBurnIn`]이 `enabled`일 때 영상 위에 합성한다(소프트 자막 트랙이 아니라 번인).
//!
//! ## 하지 않는 일
//! * 파일 프로브(길이/해상도/fps)는 [`crate::probe`]가 담당한다. 이 모듈은 프로젝트에
//!   저장된 값만 신뢰한다.
//! * 인코더 실제 지원 여부는 런타임 확인 몫이다. 그래프에는 **계획된** 인코더가 들어간다.

use serde::{Deserialize, Serialize};

use crate::error::ExportError;
use crate::export::{EncoderChoice, ExportRange, ExportSettings};
use crate::model::{ClipKind, Project, Resolution, TextAlign, TextOverlay, TrackKind};
use crate::platform::Platform;
use crate::subtitles::{SubtitleItem, SubtitleStyle};
use crate::timeline;

/// 페이드/볼륨 커브의 한 점. `at_ms`는 세그먼트 시작 기준 로컬 시각.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct CurvePoint {
    pub at_ms: i64,
    pub value: f32,
}

impl CurvePoint {
    pub fn new(at_ms: i64, value: f32) -> Self {
        Self {
            at_ms: at_ms.max(0),
            value,
        }
    }
}

/// 영상/이미지/텍스트 레이어 하나. 렌더러는 이 목록을 `layer` 순서로 합성한다.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RenderSegment {
    /// 그래프 안에서의 순서(정렬 후 부여). 로그/디버깅용이며 렌더 결과에는 영향이 없다.
    pub index: u32,
    /// 합성 순서. 작을수록 아래.
    pub layer: u32,
    pub track_id: String,
    pub track_name: String,
    pub clip_id: String,
    pub kind: ClipKind,
    /// `ClipKind::Text`면 None.
    #[serde(default)]
    pub source_path: Option<String>,
    /// 소스 인점(포함).
    pub source_in_ms: i64,
    /// 소스 아웃점(제외).
    pub source_out_ms: i64,
    /// 프로젝트 타임라인 기준 시작(포함).
    pub timeline_start_ms: i64,
    /// 프로젝트 타임라인 기준 끝(제외).
    pub timeline_end_ms: i64,
    /// 출력 파일 기준 시작(포함). `range.start_ms`만큼 당겨진 값.
    pub render_start_ms: i64,
    /// 출력 파일 기준 끝(제외).
    pub render_end_ms: i64,
    /// 이 세그먼트가 덮는 첫 프레임(포함).
    pub frame_start: u64,
    /// 마지막 프레임 + 1(제외).
    pub frame_end: u64,
    pub speed: f32,
    /// 기본 불투명도(커브의 기준값).
    pub opacity: f32,
    /// 시작~끝 불투명도 커브. 항상 2개 이상의 점을 가진다.
    pub opacity_curve: Vec<CurvePoint>,
    /// 텍스트 클립이면 그 내용/스타일.
    #[serde(default)]
    pub text: Option<TextOverlay>,
}

impl RenderSegment {
    /// 이 세그먼트가 덮는 프레임 수.
    pub fn frame_count(&self) -> u64 {
        self.frame_end.saturating_sub(self.frame_start)
    }

    /// 출력 시각 `render_ms`에서의 불투명도(선형 보간).
    pub fn opacity_at(&self, render_ms: i64) -> f32 {
        curve_value_at(&self.opacity_curve, render_ms - self.render_start_ms)
    }

    pub fn is_still_image(&self) -> bool {
        self.kind == ClipKind::Image
    }

    pub fn is_text(&self) -> bool {
        self.kind == ClipKind::Text
    }
}

/// 오디오 믹스 구간. 렌더러는 이 구간들을 전부 더한다.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AudioMixSegment {
    pub index: u32,
    pub track_id: String,
    pub clip_id: String,
    pub source_path: String,
    pub source_in_ms: i64,
    pub source_out_ms: i64,
    pub render_start_ms: i64,
    pub render_end_ms: i64,
    pub frame_start: u64,
    pub frame_end: u64,
    pub speed: f32,
    /// 기본 선형 게인(트랙 게인 × 클립 볼륨).
    pub gain: f32,
    /// 시작~끝 게인 커브(페이드 포함). 값은 기본 게인을 이미 곱한 절대 게인이며,
    /// 항상 2개 이상의 점을 가진다.
    pub gain_curve: Vec<CurvePoint>,
    /// 뮤트된 트랙에서 왔는가. true면 렌더러가 0으로 믹스한다(구간은 유지 — UI 표시용).
    pub muted: bool,
    /// 비디오 트랙의 클립에서 온 오디오인가(소스에 오디오가 없을 수 있다).
    pub from_video_track: bool,
    /// 오디오 스트림 존재가 프로브로 확인되었는가. `None`이면 렌더러가 확인해야 한다.
    #[serde(default)]
    pub has_audio_stream: Option<bool>,
}

impl AudioMixSegment {
    pub fn duration_ms(&self) -> i64 {
        self.render_end_ms - self.render_start_ms
    }

    pub fn gain_at(&self, render_ms: i64) -> f32 {
        if self.muted {
            return 0.0;
        }
        // 커브 값은 이미 기본 게인(트랙 × 볼륨)을 곱한 절대값이다.
        curve_value_at(&self.gain_curve, render_ms - self.render_start_ms)
    }
}

/// 자막 한 줄의 번인 스펙.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SubtitleBurnItem {
    pub id: String,
    pub text: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub render_start_ms: i64,
    pub render_end_ms: i64,
    pub frame_start: u64,
    pub frame_end: u64,
    /// 아이템별 스타일(없으면 트랙 스타일을 상속한 값이 들어온다).
    pub style: SubtitleStyle,
    /// 줄바꿈이 적용된 표시 문자열(렌더러가 그대로 그린다).
    pub display_text: String,
}

/// 자막 오버레이/번인 전체 스펙.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SubtitleBurnIn {
    /// 프로젝트 자막 트랙이 켜져 있고 내보내기 설정이 번인을 요청했는가.
    pub enabled: bool,
    pub style: SubtitleStyle,
    pub items: Vec<SubtitleBurnItem>,
}

impl SubtitleBurnIn {
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn item_at(&self, render_ms: i64) -> Option<&SubtitleBurnItem> {
        self.items
            .iter()
            .find(|i| render_ms >= i.render_start_ms && render_ms < i.render_end_ms)
    }
}

/// 컴파일된 렌더 그래프.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RenderGraph {
    pub project_id: String,
    pub project_name: String,
    pub platform: String,
    pub container: String,
    pub video_codec: String,
    pub audio_codec: String,
    pub encoder: EncoderChoice,
    pub resolution: Resolution,
    pub fps: u32,
    pub gop_frames: u32,
    pub video_bitrate_kbps: u32,
    pub sample_rate: u32,
    /// 출력 길이(ms).
    pub duration_ms: i64,
    /// 출력 총 프레임 수.
    pub frame_count: u64,
    /// 적용된 내보내기 구간(없으면 전체).
    #[serde(default)]
    pub range: Option<ExportRange>,
    pub segments: Vec<RenderSegment>,
    pub audio_segments: Vec<AudioMixSegment>,
    pub subtitles: SubtitleBurnIn,
    /// 제품 원칙상 항상 false.
    pub watermark: bool,
    pub notes: Vec<String>,
    /// 그래프 내용의 지문(16자리 hex). 같은 입력이면 항상 같다.
    pub graph_digest: String,
}

impl RenderGraph {
    /// 타임라인을 렌더 그래프로 컴파일한다.
    ///
    /// 실패하는 경우는 설정이 플랫폼/컨테이너 규칙에 맞지 않을 때뿐이다.
    /// 빈 타임라인은 길이 0의 유효한 그래프가 된다.
    pub fn compile(
        project: &Project,
        settings: &ExportSettings,
        platform: Platform,
    ) -> Result<RenderGraph, ExportError> {
        settings.validate_for(platform)?;

        let project_duration = project.duration_ms().max(0);
        let range = match settings.range {
            Some(range) => {
                let start = range.start_ms.max(0);
                let end = range.end_ms.min(project_duration);
                if start >= end {
                    return Err(ExportError::InvalidRange {
                        start: range.start_ms,
                        end: range.end_ms,
                    });
                }
                Some(ExportRange {
                    start_ms: start,
                    end_ms: end,
                })
            }
            None => None,
        };
        let origin = range.map(|r| r.start_ms).unwrap_or(0);
        let duration_ms = match range {
            Some(r) => r.end_ms - r.start_ms,
            None => project_duration,
        };
        let fps = settings.fps.max(1);
        let frame_count = ms_to_frame(duration_ms, fps) as u64;
        let encoder = settings.encoder_for(platform);

        let mut segments: Vec<RenderSegment> = Vec::new();
        let mut audio_segments: Vec<AudioMixSegment> = Vec::new();

        for (layer, track) in project.tracks.iter().enumerate() {
            if track.hidden || track.kind == TrackKind::Audio {
                continue;
            }
            let mut clips: Vec<_> = track.clips.iter().filter(|c| c.enabled).collect();
            clips.sort_by(|a, b| {
                a.timeline_offset_ms
                    .cmp(&b.timeline_offset_ms)
                    .then_with(|| a.id.as_str().cmp(b.id.as_str()))
            });

            for clip in clips {
                let visible_start = clip.timeline_offset_ms.max(origin);
                let visible_end = clip.timeline_end_ms().min(
                    range
                        .map(|r| r.end_ms)
                        .unwrap_or(i64::MAX)
                        .min(project_duration),
                );
                if visible_end <= visible_start {
                    continue;
                }
                // 오디오: 오디오 성격 클립은 소리도 함께 내보낸다.
                if clip.kind == ClipKind::Video
                    && !track.muted
                    && clip.volume > 0.0
                    && !clip.source_path.trim().is_empty()
                {
                    audio_segments.push(AudioMixSegment {
                        index: 0,
                        track_id: track.id.to_string(),
                        clip_id: clip.id.to_string(),
                        source_path: clip.source_path.clone(),
                        source_in_ms: clip.source_time_at(visible_start),
                        source_out_ms: clip.source_time_at(visible_end),
                        render_start_ms: visible_start - origin,
                        render_end_ms: visible_end - origin,
                        frame_start: ms_to_frame(visible_start - origin, fps) as u64,
                        frame_end: ms_to_frame(visible_end - origin, fps) as u64,
                        speed: clip.speed,
                        gain: track.gain * clip.volume,
                        gain_curve: gain_curve(
                            clip,
                            track.gain * clip.volume,
                            visible_start,
                            visible_end,
                        ),
                        muted: false,
                        from_video_track: true,
                        has_audio_stream: None,
                    });
                }

                if !clip.kind.is_visual() {
                    continue;
                }

                segments.push(RenderSegment {
                    index: 0,
                    layer: layer as u32,
                    track_id: track.id.to_string(),
                    track_name: track.name.clone(),
                    clip_id: clip.id.to_string(),
                    kind: clip.kind,
                    source_path: if clip.source_path.trim().is_empty() {
                        None
                    } else {
                        Some(clip.source_path.clone())
                    },
                    source_in_ms: if clip.kind == ClipKind::Text {
                        0
                    } else {
                        clip.source_time_at(visible_start)
                    },
                    source_out_ms: if clip.kind == ClipKind::Text {
                        visible_end - visible_start
                    } else {
                        clip.source_time_at(visible_end)
                    },
                    timeline_start_ms: visible_start,
                    timeline_end_ms: visible_end,
                    render_start_ms: visible_start - origin,
                    render_end_ms: visible_end - origin,
                    frame_start: ms_to_frame(visible_start - origin, fps) as u64,
                    frame_end: ms_to_frame(visible_end - origin, fps) as u64,
                    speed: clip.speed,
                    opacity: clip.opacity,
                    opacity_curve: opacity_curve(clip, visible_start, visible_end),
                    text: clip.text.clone(),
                });
            }
        }

        for track in project.tracks.iter().filter(|t| t.kind == TrackKind::Audio) {
            let mut clips: Vec<_> = track.clips.iter().filter(|c| c.enabled).collect();
            clips.sort_by(|a, b| {
                a.timeline_offset_ms
                    .cmp(&b.timeline_offset_ms)
                    .then_with(|| a.id.as_str().cmp(b.id.as_str()))
            });
            for clip in clips {
                let visible_start = clip.timeline_offset_ms.max(origin);
                let visible_end = clip.timeline_end_ms().min(
                    range
                        .map(|r| r.end_ms)
                        .unwrap_or(i64::MAX)
                        .min(project_duration),
                );
                if visible_end <= visible_start {
                    continue;
                }
                audio_segments.push(AudioMixSegment {
                    index: 0,
                    track_id: track.id.to_string(),
                    clip_id: clip.id.to_string(),
                    source_path: clip.source_path.clone(),
                    source_in_ms: clip.source_time_at(visible_start),
                    source_out_ms: clip.source_time_at(visible_end),
                    render_start_ms: visible_start - origin,
                    render_end_ms: visible_end - origin,
                    frame_start: ms_to_frame(visible_start - origin, fps) as u64,
                    frame_end: ms_to_frame(visible_end - origin, fps) as u64,
                    speed: clip.speed,
                    gain: track.gain * clip.volume,
                    gain_curve: gain_curve(
                        clip,
                        track.gain * clip.volume,
                        visible_start,
                        visible_end,
                    ),
                    muted: track.muted || clip.volume <= 0.0,
                    from_video_track: false,
                    has_audio_stream: None,
                });
            }
        }

        // 결정적 정렬: 출력 시각 → 레이어 → id.
        segments.sort_by(|a, b| {
            a.render_start_ms
                .cmp(&b.render_start_ms)
                .then_with(|| a.layer.cmp(&b.layer))
                .then_with(|| a.clip_id.cmp(&b.clip_id))
        });
        for (index, segment) in segments.iter_mut().enumerate() {
            segment.index = index as u32;
        }
        audio_segments.sort_by(|a, b| {
            a.render_start_ms
                .cmp(&b.render_start_ms)
                .then_with(|| a.track_id.cmp(&b.track_id))
                .then_with(|| a.clip_id.cmp(&b.clip_id))
        });
        for (index, segment) in audio_segments.iter_mut().enumerate() {
            segment.index = index as u32;
        }

        let subtitles = subtitle_burn_in(project, settings, origin, duration_ms, fps);

        let mut notes = vec![encoder.notes.clone()];
        notes.push(format!(
            "렌더 그래프: 영상 {}개 / 오디오 {}개 / 자막 {}개",
            segments.len(),
            audio_segments.len(),
            subtitles.items.len()
        ));
        if let Some(range) = range {
            notes.push(format!(
                "내보내기 구간 {}~{} ({}ms)",
                range.start_ms, range.end_ms, duration_ms
            ));
        }
        if subtitles.enabled && subtitles.is_empty() {
            notes.push("자막 번인이 켜져 있지만 구간 내 자막이 없습니다".to_string());
        }
        if !settings.burn_in_subtitles && !project.subtitles.items.is_empty() {
            notes.push("자막 번인이 꺼져 있어 자막은 영상에 그려지지 않습니다".to_string());
        }

        let mut graph = RenderGraph {
            project_id: project.id.clone(),
            project_name: project.name.clone(),
            platform: platform.id().to_string(),
            container: settings.container.as_str().to_string(),
            video_codec: settings.codec.as_str().to_string(),
            audio_codec: settings.audio_codec.as_str().to_string(),
            encoder,
            resolution: settings.resolution,
            fps,
            gop_frames: settings.gop_frames.max(1),
            video_bitrate_kbps: settings.video_bitrate_kbps,
            sample_rate: project.sample_rate.max(1),
            duration_ms,
            frame_count,
            range,
            segments,
            audio_segments,
            subtitles,
            watermark: false,
            notes,
            graph_digest: String::new(),
        };
        graph.graph_digest = graph.compute_digest();
        Ok(graph)
    }

    /// 지문을 뺀 내용으로 지문을 계산한다(자기 참조 방지).
    fn compute_digest(&self) -> String {
        let mut copy = self.clone();
        copy.graph_digest = String::new();
        match serde_json::to_string(&copy) {
            Ok(text) => fnv1a64_hex(text.as_bytes()),
            Err(_) => String::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.segments.is_empty() && self.audio_segments.is_empty()
    }

    /// 출력 프레임 번호에 그려야 하는 세그먼트(레이어 오름차순).
    pub fn segments_at_frame(&self, frame: u64) -> Vec<&RenderSegment> {
        let mut found: Vec<&RenderSegment> = self
            .segments
            .iter()
            .filter(|s| frame >= s.frame_start && frame < s.frame_end)
            .collect();
        found.sort_by_key(|s| s.layer);
        found
    }

    /// 출력 시각(ms)에 재생할 오디오 구간.
    pub fn audio_at(&self, render_ms: i64) -> Vec<&AudioMixSegment> {
        self.audio_segments
            .iter()
            .filter(|a| render_ms >= a.render_start_ms && render_ms < a.render_end_ms)
            .collect()
    }

    /// 그래프 불변식 점검. 비어 있으면 정상.
    pub fn validate(&self) -> Vec<String> {
        let mut issues = Vec::new();
        if self.watermark {
            issues.push("렌더 그래프에 워터마크가 표시되어 있습니다".to_string());
        }
        if self.fps == 0 {
            issues.push("fps가 0입니다".to_string());
        }
        if self.resolution.width == 0 || self.resolution.height == 0 {
            issues.push("해상도가 0입니다".to_string());
        }
        if self.graph_digest.is_empty() {
            issues.push("graph_digest가 비어 있습니다".to_string());
        }
        if self.graph_digest != self.compute_digest() {
            issues.push("graph_digest가 내용과 일치하지 않습니다".to_string());
        }
        for (index, segment) in self.segments.iter().enumerate() {
            if segment.index as usize != index {
                issues.push(format!("세그먼트 index가 순서와 다릅니다: {index}"));
            }
            if segment.frame_end <= segment.frame_start {
                issues.push(format!(
                    "{}: 프레임 범위가 비었습니다({}~{})",
                    segment.clip_id, segment.frame_start, segment.frame_end
                ));
            }
            if segment.render_end_ms <= segment.render_start_ms {
                issues.push(format!("{}: 출력 구간이 비었습니다", segment.clip_id));
            }
            if segment.opacity_curve.is_empty() {
                issues.push(format!("{}: 불투명도 커브가 없습니다", segment.clip_id));
            }
            if segment.kind != ClipKind::Text && segment.source_path.is_none() {
                issues.push(format!("{}: 소스 경로가 없습니다", segment.clip_id));
            }
        }
        for (index, segment) in self.audio_segments.iter().enumerate() {
            if segment.index as usize != index {
                issues.push(format!("오디오 세그먼트 index가 순서와 다릅니다: {index}"));
            }
            if segment.gain_curve.is_empty() {
                issues.push(format!("{}: 게인 커브가 없습니다", segment.clip_id));
            }
        }
        if self.subtitles.enabled {
            for item in &self.subtitles.items {
                if item.frame_end <= item.frame_start {
                    issues.push(format!("자막 {}: 프레임 범위가 비었습니다", item.id));
                }
                if item.display_text.trim().is_empty() {
                    issues.push(format!("자막 {}: 표시 문자열이 비었습니다", item.id));
                }
            }
        }
        issues
    }

    /// UI/로그용 한 줄 요약.
    pub fn summary(&self) -> String {
        format!(
            "{} {}x{}@{} · {} frames/{}ms · 영상 {} · 오디오 {} · 자막 {} · {}",
            self.container,
            self.resolution.width,
            self.resolution.height,
            self.fps,
            self.frame_count,
            self.duration_ms,
            self.segments.len(),
            self.audio_segments.len(),
            self.subtitles.items.len(),
            self.graph_digest
        )
    }

    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }
}

// ------------------------------------------------------------------ helpers

/// ms → 프레임 번호(반올림). 렌더러와 코어가 같은 규칙을 쓴다.
pub fn ms_to_frame(ms: i64, fps: u32) -> i64 {
    timeline::frame_index(ms, fps).max(0)
}

/// 커브를 선형 보간해 값 하나를 돌려준다. 범위 밖은 양 끝값으로 고정.
pub fn curve_value_at(curve: &[CurvePoint], local_ms: i64) -> f32 {
    match curve.first() {
        None => 1.0,
        Some(first) if local_ms <= first.at_ms => first.value,
        Some(_) => {
            let last = curve.last().expect("non-empty");
            if local_ms >= last.at_ms {
                return last.value;
            }
            for pair in curve.windows(2) {
                let (a, b) = (&pair[0], &pair[1]);
                if local_ms >= a.at_ms && local_ms <= b.at_ms {
                    let span = (b.at_ms - a.at_ms).max(1) as f32;
                    let t = (local_ms - a.at_ms) as f32 / span;
                    return a.value + (b.value - a.value) * t;
                }
            }
            last.value
        }
    }
}

/// 불투명도 커브: 기본 불투명도 × 페이드. 항상 시작/끝 점을 포함한다.
fn opacity_curve(
    clip: &crate::model::Clip,
    visible_start: i64,
    visible_end: i64,
) -> Vec<CurvePoint> {
    let mut points = Vec::new();
    let duration = (visible_end - visible_start).max(1);
    let base = clip.opacity;
    let start_gain = clip.gain_at(visible_start);
    let end_gain = clip.gain_at(visible_end.saturating_sub(1));
    points.push(CurvePoint::new(0, base * start_gain));
    if clip.fade_in_ms > 0 {
        let local_end = (i64::from(clip.fade_in_ms) - (visible_start - clip.timeline_offset_ms))
            .clamp(0, duration);
        if local_end > 0 && local_end < duration {
            points.push(CurvePoint::new(local_end, base));
        }
    }
    if clip.fade_out_ms > 0 {
        let local_start = duration - i64::from(clip.fade_out_ms);
        if local_start > 0 && local_start < duration {
            points.push(CurvePoint::new(local_start, base));
        }
    }
    points.push(CurvePoint::new(duration, base * end_gain));
    points.sort_by_key(|p| p.at_ms);
    points.dedup_by_key(|p| p.at_ms);
    points
}

/// 게인 커브: 기본 게인 × 페이드.
fn gain_curve(
    clip: &crate::model::Clip,
    base_gain: f32,
    visible_start: i64,
    visible_end: i64,
) -> Vec<CurvePoint> {
    let duration = (visible_end - visible_start).max(1);
    let start_gain = clip.gain_at(visible_start);
    let end_gain = clip.gain_at(visible_end.saturating_sub(1));
    let mut points = vec![CurvePoint::new(0, base_gain * start_gain)];
    if clip.fade_in_ms > 0 {
        let local_end = (i64::from(clip.fade_in_ms) - (visible_start - clip.timeline_offset_ms))
            .clamp(0, duration);
        if local_end > 0 && local_end < duration {
            points.push(CurvePoint::new(local_end, base_gain));
        }
    }
    if clip.fade_out_ms > 0 {
        let local_start = duration - i64::from(clip.fade_out_ms);
        if local_start > 0 && local_start < duration {
            points.push(CurvePoint::new(local_start, base_gain));
        }
    }
    points.push(CurvePoint::new(duration, base_gain * end_gain));
    points.sort_by_key(|p| p.at_ms);
    points.dedup_by_key(|p| p.at_ms);
    points
}

fn subtitle_burn_in(
    project: &Project,
    settings: &ExportSettings,
    origin: i64,
    duration_ms: i64,
    fps: u32,
) -> SubtitleBurnIn {
    let track = &project.subtitles;
    let enabled = track.enabled && settings.burn_in_subtitles;
    if !enabled {
        return SubtitleBurnIn {
            enabled: false,
            style: track.style.clone(),
            items: Vec::new(),
        };
    }
    let end_limit = origin + duration_ms;
    let mut items: Vec<SubtitleBurnItem> = track
        .items
        .iter()
        .filter(|item| item.end_ms > origin && item.start_ms < end_limit)
        .map(|item| {
            let start = item.start_ms.max(origin);
            let end = item.end_ms.min(end_limit);
            let style = item.style.clone().unwrap_or_else(|| track.style.clone());
            SubtitleBurnItem {
                id: item.id.to_string(),
                text: item.text.clone(),
                start_ms: item.start_ms,
                end_ms: item.end_ms,
                render_start_ms: start - origin,
                render_end_ms: end - origin,
                frame_start: ms_to_frame(start - origin, fps) as u64,
                frame_end: ms_to_frame(end - origin, fps) as u64,
                display_text: wrap_text(&item.text, style.max_chars_per_line),
                style,
            }
        })
        .collect();
    items.sort_by(|a, b| {
        a.render_start_ms
            .cmp(&b.render_start_ms)
            .then_with(|| a.id.cmp(&b.id))
    });
    SubtitleBurnIn {
        enabled: true,
        style: track.style.clone(),
        items,
    }
}

/// 자막 줄바꿈: 공백 기준, 최대 글자 수. 렌더러가 그대로 그릴 수 있게 코어가 결정한다.
pub fn wrap_text(text: &str, max_chars: u32) -> String {
    let limit = max_chars.max(1) as usize;
    let mut lines: Vec<String> = Vec::new();
    let mut current = String::new();
    for word in text.split_whitespace() {
        if current.is_empty() {
            current.push_str(word);
        } else if current.chars().count() + 1 + word.chars().count() <= limit {
            current.push(' ');
            current.push_str(word);
        } else {
            lines.push(std::mem::take(&mut current));
            current.push_str(word);
        }
    }
    if !current.is_empty() {
        lines.push(current);
    }
    if lines.is_empty() {
        return text.trim().to_string();
    }
    lines.join("\n")
}

/// FNV-1a 64비트. 의존성 없이 결정적 지문을 만든다.
pub fn fnv1a64_hex(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// 자막 스타일을 화면 좌표(정규화)로 변환한 값. 네이티브 레이어가 같은 배치를 쓰도록.
pub fn subtitle_anchor(style: &SubtitleStyle) -> (f32, f32, TextAlign) {
    (style.anchor.x, style.anchor.y, style.align)
}

/// 자막 아이템을 만들 때 트랙 스타일을 상속시킨다(렌더러 계약 문서용 헬퍼).
pub fn resolved_style(track_style: &SubtitleStyle, item: &SubtitleItem) -> SubtitleStyle {
    item.style.clone().unwrap_or_else(|| track_style.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::{AudioCodec, Container, VideoCodec};
    use crate::ids::IdSeq;
    use crate::model::{Clip, TextOverlay, Track};
    use crate::subtitles::SubtitleTrack;

    fn project_with_two_clips() -> Project {
        let mut project = Project::blank("그래프", Resolution::VERTICAL_1080P, 30);
        let mut ids = IdSeq::default();
        let video = project.tracks[0].id.clone();

        let mut first = Clip::new_media(ids.mint_clip(), ClipKind::Video, "/media/a.mp4", 0, 4_000);
        first.id = project.mint_clip_id();
        first.timeline_offset_ms = 0;
        first.fade_in_ms = 500;

        let mut second = Clip::new_media(
            ids.mint_clip(),
            ClipKind::Video,
            "/media/b.mp4",
            1_000,
            5_000,
        );
        second.id = project.mint_clip_id();
        second.timeline_offset_ms = 4_000;
        second.speed = 2.0;
        second.volume = 0.5;

        let track = project.track_mut(&video).expect("video");
        track.clips.push(first);
        track.clips.push(second);
        track.sort_clips();
        project
    }

    #[test]
    fn empty_timeline_compiles_to_empty_graph() {
        let project = Project::blank("빈 프로젝트", Resolution::VERTICAL_1080P, 30);
        let graph =
            RenderGraph::compile(&project, &project.export, Platform::MacOs).expect("compile");
        assert!(graph.is_empty());
        assert_eq!(graph.duration_ms, 0);
        assert_eq!(graph.frame_count, 0);
        assert!(graph.validate().is_empty(), "{:?}", graph.validate());
        assert!(!graph.watermark);
        assert_eq!(graph.graph_digest.len(), 16);
    }

    #[test]
    fn segments_carry_speed_trim_and_frames() {
        let project = project_with_two_clips();
        let graph =
            RenderGraph::compile(&project, &project.export, Platform::Android).expect("compile");
        assert_eq!(graph.segments.len(), 2);
        assert_eq!(graph.duration_ms, 6_000);
        assert_eq!(graph.frame_count, 180);

        let second = &graph.segments[1];
        assert_eq!(second.render_start_ms, 4_000);
        assert_eq!(second.render_end_ms, 6_000);
        assert!((second.speed - 2.0).abs() < f32::EPSILON);
        // 2배속이므로 소스는 1000→5000ms를 사용한다(타임라인 2000ms).
        assert_eq!(second.source_in_ms, 1_000);
        assert_eq!(second.source_out_ms, 5_000);
        assert_eq!(second.frame_start, 120);
        assert_eq!(second.frame_end, 180);
        assert_eq!(graph.segments_at_frame(150).len(), 1);
        assert!(graph.segments_at_frame(200).is_empty());
    }

    #[test]
    fn export_range_shifts_render_time_and_clips() {
        let project = project_with_two_clips();
        let mut settings = project.export.clone();
        settings.range = Some(ExportRange {
            start_ms: 1_000,
            end_ms: 5_000,
        });
        let graph = RenderGraph::compile(&project, &settings, Platform::Windows).expect("compile");
        assert_eq!(graph.duration_ms, 4_000);
        assert_eq!(graph.frame_count, 120);
        let first = &graph.segments[0];
        assert_eq!(first.render_start_ms, 0);
        assert_eq!(first.timeline_start_ms, 1_000);
        assert_eq!(first.source_in_ms, 1_000);
        assert_eq!(first.frame_start, 0);
        let second = &graph.segments[1];
        assert_eq!(second.timeline_start_ms, 4_000);
        assert_eq!(second.render_start_ms, 3_000);
        assert_eq!(second.frame_start, 90);
    }

    #[test]
    fn range_outside_timeline_is_rejected() {
        let project = project_with_two_clips();
        let mut settings = project.export.clone();
        settings.range = Some(ExportRange {
            start_ms: 9_000,
            end_ms: 10_000,
        });
        let err = RenderGraph::compile(&project, &settings, Platform::MacOs).expect_err("range");
        assert_eq!(
            err,
            ExportError::InvalidRange {
                start: 9_000,
                end: 10_000
            }
        );
    }

    #[test]
    fn audio_mix_includes_fades_and_track_gain() {
        let mut project = project_with_two_clips();
        let audio = project.tracks[1].id.clone();
        let mut ids = IdSeq::default();
        let mut clip =
            Clip::new_media(ids.mint_clip(), ClipKind::Audio, "/media/bgm.m4a", 0, 6_000);
        clip.id = project.mint_clip_id();
        clip.volume = 0.8;
        clip.fade_in_ms = 1_000;
        clip.fade_out_ms = 1_000;
        {
            let track = project.track_mut(&audio).expect("audio");
            track.gain = 0.5;
            track.clips.push(clip);
        }

        let graph =
            RenderGraph::compile(&project, &project.export, Platform::Ios).expect("compile");
        assert_eq!(graph.audio_segments.len(), 3);
        let bgm = graph
            .audio_segments
            .iter()
            .find(|a| a.track_id == audio.to_string())
            .expect("bgm");
        assert!((bgm.gain - 0.4).abs() < 1e-5);
        assert_eq!(bgm.gain_curve.first().unwrap().value, 0.0);
        assert!((bgm.gain_at(3_000) - 0.4).abs() < 1e-5);
        assert!(bgm.gain_at(5_900) < 0.1);
        assert_eq!(bgm.frame_end, 180);
    }

    #[test]
    fn muted_audio_track_is_kept_but_silent() {
        let mut project = project_with_two_clips();
        let audio = project.tracks[1].id.clone();
        let mut ids = IdSeq::default();
        let mut clip =
            Clip::new_media(ids.mint_clip(), ClipKind::Audio, "/media/bgm.m4a", 0, 2_000);
        clip.id = project.mint_clip_id();
        {
            let track = project.track_mut(&audio).expect("audio");
            track.muted = true;
            track.clips.push(clip);
        }
        let graph =
            RenderGraph::compile(&project, &project.export, Platform::MacOs).expect("compile");
        let muted = graph
            .audio_segments
            .iter()
            .find(|a| a.track_id == audio.to_string())
            .expect("muted segment");
        assert!(muted.muted);
        assert_eq!(muted.gain_at(500), 0.0);
    }

    #[test]
    fn subtitles_are_resolved_and_wrapped() {
        let mut project = project_with_two_clips();
        let mut style = SubtitleStyle::default();
        style.max_chars_per_line = 8;
        project.subtitles = SubtitleTrack {
            enabled: true,
            style,
            items: Vec::new(),
        };
        let id = project.mint_subtitle_id();
        project.subtitles.items.push(SubtitleItem::new(
            id,
            500,
            2_500,
            "오늘은 상하이 마라톤 준비 마지막 주",
        ));

        let graph =
            RenderGraph::compile(&project, &project.export, Platform::Windows).expect("compile");
        assert!(graph.subtitles.enabled);
        let item = &graph.subtitles.items[0];
        assert_eq!(item.frame_start, 15);
        assert_eq!(item.frame_end, 75);
        assert!(item.display_text.contains('\n'), "{}", item.display_text);
        assert!(graph.subtitles.item_at(1_000).is_some());
        assert!(graph.subtitles.item_at(4_000).is_none());
    }

    #[test]
    fn subtitle_burn_in_can_be_disabled() {
        let mut project = project_with_two_clips();
        let id = project.mint_subtitle_id();
        project
            .subtitles
            .items
            .push(SubtitleItem::new(id, 0, 1_000, "자막"));
        let mut settings = project.export.clone();
        settings.burn_in_subtitles = false;
        let graph = RenderGraph::compile(&project, &settings, Platform::Ios).expect("compile");
        assert!(!graph.subtitles.enabled);
        assert!(graph.subtitles.items.is_empty());
    }

    #[test]
    fn graph_is_deterministic_and_order_independent() {
        let project = project_with_two_clips();
        let a = RenderGraph::compile(&project, &project.export, Platform::MacOs).expect("a");
        let b = RenderGraph::compile(&project, &project.export, Platform::MacOs).expect("b");
        assert_eq!(a.graph_digest, b.graph_digest);
        assert_eq!(a, b);

        // 클립 삽입 순서를 뒤집어도 같은 그래프가 나온다.
        let mut reversed = project.clone();
        reversed.tracks[0].clips.reverse();
        let c = RenderGraph::compile(&reversed, &reversed.export, Platform::MacOs).expect("c");
        assert_eq!(a.graph_digest, c.graph_digest);
    }

    #[test]
    fn different_content_changes_digest() {
        let project = project_with_two_clips();
        let a = RenderGraph::compile(&project, &project.export, Platform::MacOs).expect("a");
        let mut changed = project.clone();
        changed.tracks[0].clips[1].volume = 0.2;
        let b = RenderGraph::compile(&changed, &changed.export, Platform::MacOs).expect("b");
        assert_ne!(a.graph_digest, b.graph_digest);
    }

    #[test]
    fn text_clip_is_a_top_layer_without_source() {
        let mut project = Project::blank("텍스트", Resolution::VERTICAL_1080P, 30);
        let overlay = project
            .tracks
            .iter()
            .find(|t| t.kind == TrackKind::Overlay)
            .expect("overlay")
            .id
            .clone();
        let mut ids = IdSeq::default();
        let mut text = Clip::new_text(ids.mint_clip(), TextOverlay::new("안녕"), 2_000);
        text.id = project.mint_clip_id();
        project.track_mut(&overlay).expect("track").clips.push(text);
        let graph =
            RenderGraph::compile(&project, &project.export, Platform::Android).expect("compile");
        assert_eq!(graph.segments.len(), 1);
        let segment = &graph.segments[0];
        assert!(segment.is_text());
        assert_eq!(segment.source_path, None);
        assert_eq!(segment.layer, 2);
        assert_eq!(segment.frame_end, 60);
        assert!(segment.text.is_some());
    }

    #[test]
    fn codec_and_container_rules_are_enforced() {
        let project = project_with_two_clips();
        let mut settings = project.export.clone();
        settings.codec = VideoCodec::ProRes;
        settings.container = Container::Mp4;
        assert!(RenderGraph::compile(&project, &settings, Platform::MacOs).is_err());

        settings.container = Container::Mov;
        settings.audio_codec = AudioCodec::Aac;
        let graph = RenderGraph::compile(&project, &settings, Platform::MacOs).expect("prores");
        assert_eq!(graph.video_codec, "prores");
        assert!(!graph.watermark);
    }

    #[test]
    fn curve_interpolation_is_clamped_at_edges() {
        let curve = vec![CurvePoint::new(0, 0.0), CurvePoint::new(1_000, 1.0)];
        assert_eq!(curve_value_at(&curve, -50), 0.0);
        assert!((curve_value_at(&curve, 500) - 0.5).abs() < 1e-6);
        assert_eq!(curve_value_at(&curve, 5_000), 1.0);
    }

    #[test]
    fn helper_wraps_text_on_word_boundaries() {
        let wrapped = wrap_text("가 나 다 라 마", 5);
        assert_eq!(wrapped, "가 나 다\n라 마");
    }

    #[test]
    fn validate_detects_tampered_digest() {
        let project = project_with_two_clips();
        let mut graph =
            RenderGraph::compile(&project, &project.export, Platform::MacOs).expect("compile");
        graph.graph_digest = "0".repeat(16);
        assert!(graph
            .validate()
            .iter()
            .any(|issue| issue.contains("graph_digest")));
    }

    #[test]
    fn track_helpers_expose_layer_order() {
        let project = project_with_two_clips();
        let graph = RenderGraph::compile(&project, &project.export, Platform::MacOs).expect("c");
        let layers: Vec<u32> = graph.segments.iter().map(|s| s.layer).collect();
        assert_eq!(layers, vec![0, 0]);
        let _ = Track::new(project.tracks[0].id.clone(), "x", TrackKind::Video);
    }
}
