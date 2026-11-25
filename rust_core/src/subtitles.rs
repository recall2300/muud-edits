//! 자막 모델과 SRT 내보내기.
//!
//! 자막은 클립과 분리된 전용 트랙으로 둔다. 이유:
//! * 자동 자막(Whisper)은 클립 경계와 무관하게 시간 기준으로 생성된다.
//! * SRT/VTT 같은 사이드카 파일로 그대로 내보낼 수 있어야 한다.
//! * 렌더러는 자막을 항상 최상위 레이어로 합성하면 된다.
//!
//! 2단계(자동 자막)에서는 Whisper의 세그먼트 결과를 [`SubtitleItem`]으로
//! 변환해 그대로 커맨드에 넣는다.

use serde::{Deserialize, Serialize};

use crate::error::EditError;
use crate::ids::SubtitleId;
use crate::model::{NormalizedAnchor, TextAlign};

fn default_font_family() -> String {
    "Pretendard".to_string()
}
fn default_size() -> f32 {
    56.0
}
fn default_color() -> String {
    "#FFFFFFFF".to_string()
}
fn default_outline_color() -> String {
    "#000000FF".to_string()
}
fn default_outline_px() -> f32 {
    3.0
}

/// 자막 공통 스타일.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SubtitleStyle {
    #[serde(default = "default_font_family")]
    pub font_family: String,
    #[serde(default = "default_size")]
    pub size_px: f32,
    #[serde(default = "default_color")]
    pub color: String,
    #[serde(default = "default_outline_color")]
    pub outline_color: String,
    #[serde(default = "default_outline_px")]
    pub outline_px: f32,
    #[serde(default)]
    pub background: Option<String>,
    #[serde(default)]
    pub align: TextAlign,
    #[serde(default)]
    pub anchor: NormalizedAnchor,
    #[serde(default = "default_max_chars")]
    pub max_chars_per_line: u32,
}

fn default_max_chars() -> u32 {
    20
}

impl Default for SubtitleStyle {
    fn default() -> Self {
        Self {
            font_family: default_font_family(),
            size_px: default_size(),
            color: default_color(),
            outline_color: default_outline_color(),
            outline_px: default_outline_px(),
            background: None,
            align: TextAlign::Center,
            anchor: NormalizedAnchor::default(),
            max_chars_per_line: default_max_chars(),
        }
    }
}

/// 자막 한 줄.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SubtitleItem {
    pub id: SubtitleId,
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
    /// None이면 트랙 기본 스타일을 쓴다.
    #[serde(default)]
    pub style: Option<SubtitleStyle>,
    /// 자동 생성(Whisper) 여부 — UI에서 "검토 필요" 표시에 쓴다.
    #[serde(default)]
    pub auto_generated: bool,
    /// 신뢰도(0.0~1.0, 선택).
    #[serde(default)]
    pub confidence: Option<f32>,
}

impl SubtitleItem {
    pub fn new(id: SubtitleId, start_ms: i64, end_ms: i64, text: impl Into<String>) -> Self {
        Self {
            id,
            start_ms,
            end_ms,
            text: text.into(),
            style: None,
            auto_generated: false,
            confidence: None,
        }
    }

    pub fn duration_ms(&self) -> i64 {
        self.end_ms - self.start_ms
    }

    pub fn contains(&self, at_ms: i64) -> bool {
        at_ms >= self.start_ms && at_ms < self.end_ms
    }

    pub fn validate(&self) -> Result<(), EditError> {
        if self.start_ms < 0 || self.end_ms < 0 {
            return Err(EditError::NegativeTime {
                value: self.start_ms.min(self.end_ms),
            });
        }
        if self.start_ms >= self.end_ms {
            return Err(EditError::InvalidTimeRange {
                start: self.start_ms,
                end: self.end_ms,
            });
        }
        if self.text.trim().is_empty() {
            return Err(EditError::EmptyText);
        }
        Ok(())
    }
}

/// 자막 변경 패치(부분 수정).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SubtitlePatch {
    #[serde(default)]
    pub start_ms: Option<i64>,
    #[serde(default)]
    pub end_ms: Option<i64>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub style: Option<Option<SubtitleStyle>>,
}

impl SubtitlePatch {
    pub fn is_empty(&self) -> bool {
        self.start_ms.is_none()
            && self.end_ms.is_none()
            && self.text.is_none()
            && self.style.is_none()
    }

    /// `target`에 패치를 적용한 새 아이템을 만든다(원본은 그대로).
    pub fn apply_to(&self, target: &SubtitleItem) -> SubtitleItem {
        let mut next = target.clone();
        if let Some(v) = self.start_ms {
            next.start_ms = v;
        }
        if let Some(v) = self.end_ms {
            next.end_ms = v;
        }
        if let Some(v) = &self.text {
            next.text = v.clone();
        }
        if let Some(v) = &self.style {
            next.style = v.clone();
        }
        next
    }

    /// `target`을 `patched` 이전 상태로 되돌리는 패치.
    pub fn inverse_of(&self, target: &SubtitleItem) -> SubtitlePatch {
        SubtitlePatch {
            start_ms: self.start_ms.map(|_| target.start_ms),
            end_ms: self.end_ms.map(|_| target.end_ms),
            text: self.text.as_ref().map(|_| target.text.clone()),
            style: self.style.as_ref().map(|_| target.style.clone()),
        }
    }
}

/// 자막 트랙 전체.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SubtitleTrack {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub style: SubtitleStyle,
    #[serde(default)]
    pub items: Vec<SubtitleItem>,
}

fn default_true() -> bool {
    true
}

impl Default for SubtitleTrack {
    fn default() -> Self {
        Self {
            enabled: true,
            style: SubtitleStyle::default(),
            items: Vec::new(),
        }
    }
}

impl SubtitleTrack {
    pub fn item(&self, id: &SubtitleId) -> Option<&SubtitleItem> {
        self.items.iter().find(|i| &i.id == id)
    }

    pub fn item_index(&self, id: &SubtitleId) -> Option<usize> {
        self.items.iter().position(|i| &i.id == id)
    }

    pub fn sort(&mut self) {
        self.items.sort_by_key(|i| i.start_ms);
    }

    pub fn duration_ms(&self) -> i64 {
        self.items.iter().map(|i| i.end_ms).max().unwrap_or(0)
    }

    /// 다음 자막을 붙일 기본 위치: 마지막 자막 끝 + `gap_ms`.
    pub fn append_start_ms(&self, gap_ms: i64) -> i64 {
        self.items
            .iter()
            .map(|i| i.end_ms)
            .max()
            .map(|end| end + gap_ms.max(0))
            .unwrap_or(0)
    }

    /// `[start, end)`와 겹치는 자막(자기 자신 제외).
    pub fn overlapping(
        &self,
        start: i64,
        end: i64,
        ignore: Option<&SubtitleId>,
    ) -> Option<&SubtitleItem> {
        self.items
            .iter()
            .filter(|i| Some(&i.id) != ignore)
            .find(|i| i.start_ms < end && start < i.end_ms)
    }

    /// 배치 검증: 범위와 겹침.
    pub fn check_placement(
        &self,
        start: i64,
        end: i64,
        ignore: Option<&SubtitleId>,
    ) -> Result<(), EditError> {
        if start < 0 {
            return Err(EditError::NegativeTime { value: start });
        }
        if start >= end {
            return Err(EditError::InvalidTimeRange { start, end });
        }
        if let Some(other) = self.overlapping(start, end, ignore) {
            return Err(EditError::Overlap {
                track: "subtitles".into(),
                other: other.id.to_string(),
            });
        }
        Ok(())
    }

    /// `at_ms`에 표시할 자막 텍스트.
    pub fn text_at(&self, at_ms: i64) -> Option<&str> {
        if !self.enabled {
            return None;
        }
        self.items
            .iter()
            .find(|i| i.contains(at_ms))
            .map(|i| i.text.as_str())
    }

    /// SRT(SubRip) 문자열로 내보낸다.
    ///
    /// 자막이 없으면 빈 문자열을 돌려준다(파일을 만들지 않는 판단은 호출자 몫).
    pub fn to_srt(&self) -> String {
        let mut items: Vec<&SubtitleItem> = self.items.iter().collect();
        items.sort_by_key(|i| i.start_ms);
        let mut out = String::new();
        for (index, item) in items.iter().enumerate() {
            out.push_str(&(index + 1).to_string());
            out.push('\n');
            out.push_str(&format!(
                "{} --> {}\n",
                srt_timestamp(item.start_ms),
                srt_timestamp(item.end_ms)
            ));
            for line in item.text.lines() {
                out.push_str(line.trim_end());
                out.push('\n');
            }
            out.push('\n');
        }
        out
    }

    /// WebVTT 문자열로 내보낸다.
    pub fn to_vtt(&self) -> String {
        let mut items: Vec<&SubtitleItem> = self.items.iter().collect();
        items.sort_by_key(|i| i.start_ms);
        let mut out = String::from("WEBVTT\n\n");
        for item in items {
            out.push_str(&format!(
                "{} --> {}\n{}\n\n",
                vtt_timestamp(item.start_ms),
                vtt_timestamp(item.end_ms),
                item.text
            ));
        }
        out
    }
}

fn srt_timestamp(ms: i64) -> String {
    let total = ms.max(0);
    format!(
        "{:02}:{:02}:{:02},{:03}",
        total / 3_600_000,
        (total % 3_600_000) / 60_000,
        (total % 60_000) / 1000,
        total % 1000
    )
}

fn vtt_timestamp(ms: i64) -> String {
    let total = ms.max(0);
    format!(
        "{:02}:{:02}:{:02}.{:03}",
        total / 3_600_000,
        (total % 3_600_000) / 60_000,
        (total % 60_000) / 1000,
        total % 1000
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track_with_two() -> SubtitleTrack {
        let mut track = SubtitleTrack::default();
        track.items.push(SubtitleItem::new(
            SubtitleId::new("sub-0002"),
            2_000,
            3_500,
            "두 번째",
        ));
        track.items.push(SubtitleItem::new(
            SubtitleId::new("sub-0001"),
            0,
            1_500,
            "첫 번째\n둘째 줄",
        ));
        track
    }

    #[test]
    fn srt_output_is_ordered_and_formatted() {
        let srt = track_with_two().to_srt();
        assert!(srt.starts_with("1\n00:00:00,000 --> 00:00:01,500\n첫 번째\n둘째 줄\n\n"));
        assert!(srt.contains("2\n00:00:02,000 --> 00:00:03,500\n두 번째\n"));
    }

    #[test]
    fn vtt_has_header() {
        let vtt = track_with_two().to_vtt();
        assert!(vtt.starts_with("WEBVTT\n\n"));
        assert!(vtt.contains("00:00:02.000 --> 00:00:03.500"));
    }

    #[test]
    fn placement_rejects_overlap_but_allows_touching() {
        let track = track_with_two();
        assert!(track.check_placement(1_500, 2_000, None).is_ok());
        assert!(track.check_placement(1_000, 2_500, None).is_err());
        assert!(track
            .check_placement(1_000, 2_500, Some(&SubtitleId::new("sub-0002")))
            .is_err());
    }

    #[test]
    fn append_start_uses_last_end() {
        assert_eq!(track_with_two().append_start_ms(200), 3_700);
        assert_eq!(SubtitleTrack::default().append_start_ms(200), 0);
    }

    #[test]
    fn patch_inverse_restores_previous_state() {
        let item = SubtitleItem::new(SubtitleId::new("sub-0001"), 0, 1_000, "원본");
        let patch = SubtitlePatch {
            text: Some("수정".into()),
            end_ms: Some(1_200),
            ..Default::default()
        };
        let patched = patch.apply_to(&item);
        assert_eq!(patched.text, "수정");
        let inverse = patch.inverse_of(&item);
        let restored = inverse.apply_to(&patched);
        assert_eq!(restored, item);
    }

    #[test]
    fn text_at_respects_enabled_flag() {
        let mut track = track_with_two();
        assert_eq!(track.text_at(1_000), Some("첫 번째\n둘째 줄"));
        track.enabled = false;
        assert_eq!(track.text_at(1_000), None);
    }
}
