//! 오류 타입.
//!
//! 커맨드는 "실패하면 아무것도 바꾸지 않는다"를 지키므로, 모든 검증 오류는
//! 변이 전에 [`EditError`]로 반환된다. UI는 이 문자열을 그대로 토스트로 띄울 수 있다.

use thiserror::Error;

/// 편집 커맨드/타임라인 검증 오류.
#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum EditError {
    #[error("트랙을 찾을 수 없습니다: {0}")]
    TrackNotFound(String),

    #[error("클립을 찾을 수 없습니다: {0}")]
    ClipNotFound(String),

    #[error("자막을 찾을 수 없습니다: {0}")]
    SubtitleNotFound(String),

    #[error("트랙이 잠겨 있습니다: {0}")]
    TrackLocked(String),

    #[error("{track} 트랙에는 {clip} 클립을 올릴 수 없습니다")]
    IncompatibleTrackKind { track: String, clip: String },

    #[error("시간 범위가 올바르지 않습니다: 시작 {start}ms >= 끝 {end}ms")]
    InvalidTimeRange { start: i64, end: i64 },

    #[error("음수 시간은 사용할 수 없습니다: {value}ms")]
    NegativeTime { value: i64 },

    #[error("{track} 트랙에서 {other} 클립과 겹칩니다")]
    Overlap { track: String, other: String },

    #[error("분할 지점 {at}ms가 클립 {clip} 범위를 벗어났습니다")]
    SplitOutOfRange { clip: String, at: i64 },

    #[error("{field} 값이 범위를 벗어났습니다: {value}")]
    OutOfRange { field: String, value: String },

    #[error("소스 길이({limit}ms)를 넘는 구간입니다: {value}ms")]
    SourceOverflow { limit: i64, value: i64 },

    #[error("텍스트가 비어 있습니다")]
    EmptyText,

    #[error("이 클립 종류에서는 지원하지 않는 작업입니다: {0}")]
    Unsupported(&'static str),

    #[error("프로젝트가 유효하지 않습니다: {0}")]
    Invalid(String),
}

impl EditError {
    /// UI 표시용 간단 분류 키. Dart 쪽에서 아이콘/문구를 고를 때 쓴다.
    pub fn code(&self) -> &'static str {
        match self {
            EditError::TrackNotFound(_) => "track_not_found",
            EditError::ClipNotFound(_) => "clip_not_found",
            EditError::SubtitleNotFound(_) => "subtitle_not_found",
            EditError::TrackLocked(_) => "track_locked",
            EditError::IncompatibleTrackKind { .. } => "incompatible_track_kind",
            EditError::InvalidTimeRange { .. } => "invalid_time_range",
            EditError::NegativeTime { .. } => "negative_time",
            EditError::Overlap { .. } => "overlap",
            EditError::SplitOutOfRange { .. } => "split_out_of_range",
            EditError::OutOfRange { .. } => "out_of_range",
            EditError::SourceOverflow { .. } => "source_overflow",
            EditError::EmptyText => "empty_text",
            EditError::Unsupported(_) => "unsupported",
            EditError::Invalid(_) => "invalid",
        }
    }
}

/// 내보내기 설정 검증 오류.
#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum ExportError {
    #[error("워터마크가 있는 내보내기는 지원하지 않습니다")]
    WatermarkNotAllowed,

    #[error("해상도가 올바르지 않습니다: {width}x{height}")]
    InvalidResolution { width: u32, height: u32 },

    #[error("{codec} 코덱은 해상도의 가로/세로가 짝수여야 합니다: {width}x{height}")]
    OddDimensions {
        codec: String,
        width: u32,
        height: u32,
    },

    #[error("프레임레이트가 범위를 벗어났습니다: {fps}")]
    InvalidFrameRate { fps: u32 },

    #[error("비트레이트가 범위를 벗어났습니다: {kbps}kbps")]
    InvalidBitrate { kbps: u32 },

    #[error("{container} 컨테이너에 {codec} 비디오/오디오 코덱 조합을 담을 수 없습니다")]
    UnsupportedCombination { container: String, codec: String },

    #[error("내보내기 구간이 타임라인과 겹치지 않습니다: {start}ms~{end}ms")]
    InvalidRange { start: i64, end: i64 },
}

/// 프로젝트 파일 입출력 오류.
#[derive(Debug, Error)]
pub enum ProjectIoError {
    #[error("파일을 읽지 못했습니다: {0}")]
    Io(#[from] std::io::Error),

    #[error("프로젝트 JSON을 해석하지 못했습니다: {0}")]
    Json(#[from] serde_json::Error),

    #[error("지원하지 않는 프로젝트 스키마 버전입니다: {found} (지원: {supported})")]
    UnsupportedSchema { found: u32, supported: u32 },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_are_stable() {
        assert_eq!(EditError::EmptyText.code(), "empty_text");
        assert_eq!(
            EditError::Overlap {
                track: "trk-0001".into(),
                other: "clp-0002".into()
            }
            .code(),
            "overlap"
        );
    }

    #[test]
    fn messages_are_human_readable() {
        let err = EditError::InvalidTimeRange {
            start: 900,
            end: 400,
        };
        assert!(err.to_string().contains("900"));
    }
}
