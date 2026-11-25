//! 플랫폼 미디어 프로브 결과의 수신/정규화 모델.
//!
//! ## 흐름
//! ```text
//! Flutter ──(MethodChannel "probe")──▶ macOS/iOS AVAsset
//!                                      Android MediaMetadataRetriever
//!                                      Windows ffprobe / MediaFoundation
//!        ◀──(Map<길이, 해상도, fps, 오디오 유무>)──┘
//!        ──(JSON)──▶ rust_core::probe::MediaProbeInfo
//!        ──▶ 클립 생성(길이/종류) · 내보내기 검증 · UI 표시
//! ```
//!
//! 플랫폼마다 키 이름과 단위가 다르므로, 코어가 **한 번 정규화**하고 검증한다.
//! 검증에 실패하면 클립을 만들지 않는다(길이 0짜리 클립이 타임라인에 들어가는 것보다 낫다).
//!
//! ## 단위
//! * `duration_ms`: 정수 ms. AVFoundation의 초 단위 값을 네이티브에서 ms로 바꿔 보낸다.
//! * `fps`: f64(29.97 같은 값 보존). 정수 fps는 그대로 온다.
//! * 해상도는 **회전을 적용한 표시 크기**를 보낸다(`rotation_degrees`는 참고용).

use serde::{Deserialize, Serialize};

use crate::model::ClipKind;

/// 프로브한 미디어의 종류(플랫폼이 알려 준 스트림 구성에서 유도).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProbedMediaType {
    Video,
    Audio,
    Image,
    Unknown,
}

impl ProbedMediaType {
    pub fn as_str(self) -> &'static str {
        match self {
            ProbedMediaType::Video => "video",
            ProbedMediaType::Audio => "audio",
            ProbedMediaType::Image => "image",
            ProbedMediaType::Unknown => "unknown",
        }
    }

    /// 타임라인 클립 종류로. 알 수 없으면 None.
    pub fn clip_kind(self) -> Option<ClipKind> {
        match self {
            ProbedMediaType::Video => Some(ClipKind::Video),
            ProbedMediaType::Audio => Some(ClipKind::Audio),
            ProbedMediaType::Image => Some(ClipKind::Image),
            ProbedMediaType::Unknown => None,
        }
    }
}

fn default_rotation() -> i32 {
    0
}
fn default_source() -> String {
    "unknown".to_string()
}

/// 플랫폼이 돌려준 미디어 메타데이터.
///
/// 모든 필드는 `serde(default)`라서, 플랫폼이 일부 키만 보내도 해석된다.
/// 대신 [`MediaProbeInfo::validate`]가 필수 값을 확인한다.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MediaProbeInfo {
    pub path: String,
    #[serde(default)]
    pub duration_ms: i64,
    #[serde(default)]
    pub width: u32,
    #[serde(default)]
    pub height: u32,
    #[serde(default)]
    pub fps: f64,
    /// 비디오 스트림이 있는가.
    #[serde(default)]
    pub has_video: bool,
    /// 오디오 스트림이 있는가.
    #[serde(default)]
    pub has_audio: bool,
    #[serde(default)]
    pub audio_channels: Option<u32>,
    #[serde(default)]
    pub audio_sample_rate: Option<u32>,
    #[serde(default)]
    pub video_codec: Option<String>,
    #[serde(default)]
    pub audio_codec: Option<String>,
    /// 표시 회전(0/90/180/270). 해상도는 회전 반영 후 값이어야 한다.
    #[serde(default = "default_rotation")]
    pub rotation_degrees: i32,
    #[serde(default)]
    pub bitrate_kbps: Option<u32>,
    /// 컨테이너/확장자 힌트(예: `mov`, `mp4`, `m4a`, `jpg`).
    #[serde(default)]
    pub container: Option<String>,
    /// 어느 네이티브 구현이 프로브했는가: `avfoundation`, `android-media`, `ffprobe`, `mediafoundation`.
    #[serde(default = "default_source")]
    pub source: String,
    /// 프로브 시각(ms). 0이면 미기록.
    #[serde(default)]
    pub probed_at_ms: i64,
}

impl Default for MediaProbeInfo {
    fn default() -> Self {
        Self {
            path: String::new(),
            duration_ms: 0,
            width: 0,
            height: 0,
            fps: 0.0,
            has_video: false,
            has_audio: false,
            audio_channels: None,
            audio_sample_rate: None,
            video_codec: None,
            audio_codec: None,
            rotation_degrees: 0,
            bitrate_kbps: None,
            container: None,
            source: default_source(),
            probed_at_ms: 0,
        }
    }
}

impl MediaProbeInfo {
    /// 정지 이미지 프로브 결과(길이 없음).
    pub fn image(path: impl Into<String>, width: u32, height: u32) -> Self {
        Self {
            path: path.into(),
            width,
            height,
            has_video: false,
            has_audio: false,
            source: "image".to_string(),
            ..Self::default()
        }
    }

    /// 플랫폼 JSON 문자열을 해석한다. 형식 오류는 사람이 읽을 수 있는 메시지로.
    pub fn from_json(text: &str) -> Result<Self, String> {
        if text.trim().is_empty() {
            return Err("프로브 결과가 비어 있습니다".to_string());
        }
        serde_json::from_str(text)
            .map_err(|err| format!("프로브 결과 JSON을 해석하지 못했습니다: {err}"))
    }

    /// 필수 값 검증. 통과하면 `Ok(())`.
    pub fn validate(&self) -> Result<(), String> {
        if self.path.trim().is_empty() {
            return Err("미디어 경로가 비어 있습니다".to_string());
        }
        if !self.has_video && !self.has_audio && !self.is_image() {
            return Err(format!(
                "{}: 비디오/오디오/이미지 어느 스트림도 없습니다",
                self.path
            ));
        }
        if self.duration_ms < 0 {
            return Err(format!("{}: 길이가 음수입니다", self.path));
        }
        if self.has_video || self.is_image() {
            if self.width == 0 || self.height == 0 {
                return Err(format!("{}: 해상도가 0입니다", self.path));
            }
            if self.width > 16_384 || self.height > 16_384 {
                return Err(format!(
                    "{}: 해상도가 너무 큽니다 ({}x{})",
                    self.path, self.width, self.height
                ));
            }
        }
        if self.has_video && !(0.0..=240.0).contains(&self.fps) {
            return Err(format!(
                "{}: fps가 범위를 벗어났습니다: {}",
                self.path, self.fps
            ));
        }
        if self.has_video && self.duration_ms == 0 {
            return Err(format!("{}: 비디오 길이가 0입니다", self.path));
        }
        if self.has_audio {
            if let Some(channels) = self.audio_channels {
                if channels == 0 || channels > 16 {
                    return Err(format!(
                        "{}: 오디오 채널 수가 이상합니다: {channels}",
                        self.path
                    ));
                }
            }
            if let Some(rate) = self.audio_sample_rate {
                if !(8_000..=384_000).contains(&rate) {
                    return Err(format!("{}: 샘플레이트가 이상합니다: {rate}", self.path));
                }
            }
        }
        if !matches!(self.rotation_degrees % 90, 0) {
            return Err(format!(
                "{}: 회전 값이 90도 단위가 아닙니다: {}",
                self.path, self.rotation_degrees
            ));
        }
        Ok(())
    }

    /// 스트림 구성으로 미디어 종류를 판정한다.
    pub fn media_type(&self) -> ProbedMediaType {
        if self.has_video {
            ProbedMediaType::Video
        } else if self.has_audio {
            ProbedMediaType::Audio
        } else if self.is_image() {
            ProbedMediaType::Image
        } else {
            ProbedMediaType::Unknown
        }
    }

    pub fn clip_kind(&self) -> Option<ClipKind> {
        self.media_type().clip_kind()
    }

    /// 해상도가 있고 스트림이 없으면 정지 이미지로 본다(플랫폼 프로브가 종종 그렇게 준다).
    pub fn is_image(&self) -> bool {
        !self.has_video
            && !self.has_audio
            && self.width > 0
            && self.height > 0
            && self.duration_ms == 0
    }

    /// 화면 비율.
    pub fn aspect_ratio(&self) -> f64 {
        if self.height == 0 {
            0.0
        } else {
            f64::from(self.width) / f64::from(self.height)
        }
    }

    /// 클립에 넣을 기본 아웃점. 이미지/길이 0이면 None.
    pub fn suggested_end_ms(&self) -> Option<i64> {
        if self.duration_ms > 0 {
            Some(self.duration_ms)
        } else {
            None
        }
    }

    /// 클립이 사용할 수 있는 최대 아웃점(소스 범위 검사에 쓴다).
    pub fn clamp_end_ms(&self, requested: i64) -> i64 {
        match self.suggested_end_ms() {
            Some(duration) => requested.clamp(1, duration),
            None => requested.max(1),
        }
    }

    /// UI에 표시할 한 줄 요약.
    pub fn summary(&self) -> String {
        let mut parts = vec![self.media_type().as_str().to_string()];
        if self.width > 0 && self.height > 0 {
            parts.push(format!("{}x{}", self.width, self.height));
        }
        if self.fps > 0.0 {
            parts.push(format!("{:.2}fps", self.fps));
        }
        if self.duration_ms > 0 {
            parts.push(crate::timeline::format_timecode(self.duration_ms, 30));
        }
        parts.push(if self.has_audio {
            "오디오 있음".to_string()
        } else {
            "오디오 없음".to_string()
        });
        parts.join(" · ")
    }

    /// 검증 후 경고 목록을 덧붙인 사본. UI가 "왜 이렇게 들어갔는지" 보여 줄 때 쓴다.
    pub fn warnings(&self) -> Vec<String> {
        let mut warnings = Vec::new();
        if self.has_video && self.has_audio {
            // 정상.
        } else if self.media_type() == ProbedMediaType::Video {
            warnings.push("오디오 트랙이 없습니다 — 무음 영상으로 들어갑니다".to_string());
        }
        if self.media_type() == ProbedMediaType::Image {
            warnings.push("정지 이미지로 판단했습니다 — 기본 5초로 놓습니다".to_string());
        }
        if matches!(self.rotation_degrees.rem_euclid(360), 90 | 270) {
            warnings.push(format!(
                "회전된 미디어입니다({}도) — 해상도는 표시 크기 기준",
                self.rotation_degrees
            ));
        }
        if !is_standard_frame_rate(self.fps) {
            warnings.push(format!(
                "가변/비표준 프레임레이트({:.2}fps) — 내보내기에서 고정 fps로 변환",
                self.fps
            ));
        }
        warnings
    }
}

/// 23.976/29.97/59.94 같은 표준 NTSC 계열과 정수 fps는 VFR 경고 대상이 아니다.
fn is_standard_frame_rate(fps: f64) -> bool {
    const STANDARD: [f64; 10] = [
        23.976, 24.0, 25.0, 29.97, 30.0, 48.0, 50.0, 59.94, 60.0, 120.0,
    ];
    fps <= 0.0 || STANDARD.iter().any(|rate| (fps - rate).abs() < 0.02)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn video_json() -> String {
        r#"{
            "path": "/media/shanghai.mp4",
            "duration_ms": 12500,
            "width": 1080,
            "height": 1920,
            "fps": 29.97,
            "has_video": true,
            "has_audio": true,
            "audio_channels": 2,
            "audio_sample_rate": 48000,
            "video_codec": "h264",
            "audio_codec": "aac",
            "rotation_degrees": 0,
            "source": "avfoundation",
            "probed_at_ms": 1000
        }"#
        .to_string()
    }

    #[test]
    fn parses_platform_json_and_classifies_video() {
        let info = MediaProbeInfo::from_json(&video_json()).expect("parse");
        assert!(info.validate().is_ok());
        assert_eq!(info.media_type(), ProbedMediaType::Video);
        assert_eq!(info.clip_kind(), Some(ClipKind::Video));
        assert_eq!(info.suggested_end_ms(), Some(12_500));
        assert!(info.summary().contains("1080x1920"));
        assert!(info.warnings().is_empty());
    }

    #[test]
    fn audio_only_is_classified_as_audio() {
        let info = MediaProbeInfo::from_json(
            r#"{"path":"/m/bgm.m4a","duration_ms":60000,"has_audio":true,"audio_channels":2,"source":"android-media"}"#,
        )
        .expect("parse");
        assert!(info.validate().is_ok());
        assert_eq!(info.media_type(), ProbedMediaType::Audio);
        assert_eq!(info.clip_kind(), Some(ClipKind::Audio));
    }

    #[test]
    fn image_without_streams_is_image() {
        let info = MediaProbeInfo::image("/m/cover.jpg", 1080, 1350);
        assert!(info.validate().is_ok());
        assert!(info.is_image());
        assert_eq!(info.clip_kind(), Some(ClipKind::Image));
        assert_eq!(info.suggested_end_ms(), None);
        assert!(info.warnings().iter().any(|w| w.contains("정지 이미지")));
    }

    #[test]
    fn missing_path_or_streams_is_rejected() {
        let mut info = MediaProbeInfo::from_json(&video_json()).expect("parse");
        info.path = "  ".into();
        assert!(info.validate().is_err());

        let mut info = MediaProbeInfo::from_json(&video_json()).expect("parse");
        info.has_video = false;
        info.has_audio = false;
        assert!(info.validate().unwrap_err().contains("스트림"));
    }

    #[test]
    fn zero_duration_video_is_rejected() {
        let mut info = MediaProbeInfo::from_json(&video_json()).expect("parse");
        info.duration_ms = 0;
        assert!(info.validate().unwrap_err().contains("길이"));
    }

    #[test]
    fn bad_fps_and_rotation_are_rejected() {
        let mut info = MediaProbeInfo::from_json(&video_json()).expect("parse");
        info.fps = 5_000.0;
        assert!(info.validate().is_err());

        let mut info = MediaProbeInfo::from_json(&video_json()).expect("parse");
        info.rotation_degrees = 45;
        assert!(info.validate().is_err());
    }

    #[test]
    fn clamp_end_respects_probed_duration() {
        let info = MediaProbeInfo::from_json(&video_json()).expect("parse");
        assert_eq!(info.clamp_end_ms(99_000), 12_500);
        assert_eq!(info.clamp_end_ms(0), 1);
    }

    #[test]
    fn silent_video_warns_but_is_valid() {
        let mut info = MediaProbeInfo::from_json(&video_json()).expect("parse");
        info.has_audio = false;
        info.audio_channels = None;
        assert!(info.validate().is_ok());
        assert!(info.warnings().iter().any(|w| w.contains("무음")));
        assert_eq!(info.clip_kind(), Some(ClipKind::Video));
    }

    #[test]
    fn partial_json_uses_defaults() {
        let info = MediaProbeInfo::from_json(r#"{"path":"/a.mp4","duration_ms":1000,"width":2,"height":2,"has_video":true,"fps":30}"#)
            .expect("parse");
        assert_eq!(info.rotation_degrees, 0);
        assert_eq!(info.source, "unknown");
        assert_eq!(info.has_audio, false);
    }

    #[test]
    fn empty_or_broken_json_is_reported_in_korean() {
        assert!(MediaProbeInfo::from_json(" ").unwrap_err().contains("비어"));
        let err = MediaProbeInfo::from_json("{not json}").unwrap_err();
        assert!(err.contains("해석하지 못했습니다"), "{err}");
    }

    #[test]
    fn rotated_media_keeps_display_resolution() {
        let mut info = MediaProbeInfo::from_json(&video_json()).expect("parse");
        info.rotation_degrees = 90;
        info.width = 1920;
        info.height = 1080;
        assert!(info.validate().is_ok());
        assert!(info.warnings().iter().any(|w| w.contains("회전")));
        assert!((info.aspect_ratio() - 16.0 / 9.0).abs() < 1e-9);
    }
}
