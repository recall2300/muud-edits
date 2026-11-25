//! 타임라인 시간 계산 유틸리티.
//!
//! 모든 값은 밀리초(i64)지만, 사용자가 보는 눈금과 드래그 결과는 프레임 단위로
//! 맞아야 한다. UI는 스냅/드래그 결과를 [`snap_to_frame`]으로 양자화해서 커맨드에
//! 넣고, 커맨드는 프레임레이트를 모른 채 ms만 다룬다.

use crate::error::EditError;
use crate::model::Clip;

/// 1프레임의 길이(ms).
pub fn frame_duration_ms(fps: u32) -> f64 {
    if fps == 0 {
        0.0
    } else {
        1000.0 / f64::from(fps)
    }
}

/// ms → 가장 가까운 프레임 경계(ms).
pub fn snap_to_frame(ms: i64, fps: u32) -> i64 {
    let frame = frame_duration_ms(fps);
    if frame <= 0.0 {
        return ms;
    }
    ((ms as f64 / frame).round() * frame).round() as i64
}

/// ms → 프레임 번호.
pub fn frame_index(ms: i64, fps: u32) -> i64 {
    let frame = frame_duration_ms(fps);
    if frame <= 0.0 {
        return 0;
    }
    (ms as f64 / frame).round() as i64
}

/// 프레임 번호 → ms.
pub fn frame_to_ms(frame: i64, fps: u32) -> i64 {
    (frame as f64 * frame_duration_ms(fps)).round() as i64
}

/// `HH:MM:SS.mmm` 형태의 타임코드.
pub fn format_timecode(ms: i64, _fps: u32) -> String {
    let negative = ms < 0;
    let total = ms.abs();
    let hours = total / 3_600_000;
    let minutes = (total % 3_600_000) / 60_000;
    let seconds = (total % 60_000) / 1000;
    let millis = total % 1000;
    format!(
        "{}{:02}:{:02}:{:02}.{:03}",
        if negative { "-" } else { "" },
        hours,
        minutes,
        seconds,
        millis
    )
}

/// `HH:MM:SS:FF` 형태의 프레임 타임코드(편집자에게 익숙한 표기).
pub fn format_frame_timecode(ms: i64, fps: u32) -> String {
    if fps == 0 {
        return format_timecode(ms, fps);
    }
    let total_frames = frame_index(ms, fps).max(0);
    let fps_i = i64::from(fps);
    let frames = total_frames % fps_i;
    let total_seconds = total_frames / fps_i;
    format!(
        "{:02}:{:02}:{:02}:{:02}",
        total_seconds / 3600,
        (total_seconds % 3600) / 60,
        total_seconds % 60,
        frames
    )
}

/// `HH:MM:SS.mmm`, `MM:SS`, `SS` 형태를 ms로. 실패하면 None.
pub fn parse_timecode(text: &str) -> Option<i64> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    let negative = trimmed.starts_with('-');
    let body = trimmed.trim_start_matches('-');

    let (clock, fraction_ms) = match body.split_once(['.', ',']) {
        Some((clock, frac)) => {
            let millis: String = frac.chars().take(3).collect();
            let padded = format!("{millis:0<3}");
            (clock, padded.parse::<i64>().ok()?)
        }
        None => (body, 0),
    };

    let parts: Vec<&str> = clock.split(':').collect();
    if parts.is_empty() || parts.len() > 3 {
        return None;
    }
    let mut total = 0i64;
    for (index, part) in parts.iter().enumerate() {
        let value = if part.is_empty() {
            0
        } else {
            part.parse::<i64>().ok()?
        };
        if value < 0 {
            return None;
        }
        let multiplier = match parts.len() - index {
            1 => 1000,
            2 => 60_000,
            _ => 3_600_000,
        };
        total += value * multiplier;
    }
    let total = total + fraction_ms;
    Some(if negative { -total } else { total })
}

/// 분할 결과.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SplitPoint {
    /// 분할되는 소스 시각(오른쪽 클립의 인점).
    pub source_ms: i64,
    /// 오른쪽 클립이 타임라인에서 시작할 위치.
    pub right_offset_ms: i64,
}

/// 클립을 타임라인 `at_ms`에서 자를 때의 계산.
///
/// 클립 경계와 정확히 같으면 자를 것이 없으므로 오류다.
pub fn split_point(clip: &Clip, at_ms: i64) -> Result<SplitPoint, EditError> {
    let start = clip.timeline_offset_ms;
    let end = clip.timeline_end_ms();
    if at_ms <= start || at_ms >= end {
        return Err(EditError::SplitOutOfRange {
            clip: clip.id.to_string(),
            at: at_ms,
        });
    }
    let source_ms = clip.source_time_at(at_ms);
    if source_ms <= clip.start_ms || source_ms >= clip.end_ms {
        return Err(EditError::SplitOutOfRange {
            clip: clip.id.to_string(),
            at: at_ms,
        });
    }
    Ok(SplitPoint {
        source_ms,
        right_offset_ms: at_ms,
    })
}

/// 스냅 후보: 트랙의 모든 클립 경계(0과 전체 길이 포함).
pub fn snap_targets(clips: &[Clip], fps: u32) -> Vec<i64> {
    let mut targets = vec![0];
    for clip in clips {
        targets.push(snap_to_frame(clip.timeline_offset_ms, fps));
        targets.push(snap_to_frame(clip.timeline_end_ms(), fps));
    }
    targets.sort_unstable();
    targets.dedup();
    targets
}

/// `value`를 스냅 후보 중 `threshold_ms` 안에서 가장 가까운 값으로 붙인다.
pub fn snap_to_targets(value: i64, targets: &[i64], threshold_ms: i64) -> i64 {
    let mut best = value;
    let mut best_distance = threshold_ms + 1;
    for target in targets {
        let distance = (target - value).abs();
        if distance <= threshold_ms && distance < best_distance {
            best = *target;
            best_distance = distance;
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ids::{ClipId, IdSeq};
    use crate::model::{ClipKind, TextOverlay};

    fn clip(offset: i64, start: i64, end: i64, speed: f32) -> Clip {
        let mut ids = IdSeq::default();
        let mut c = Clip::new_media(
            ids.mint_clip(),
            ClipKind::Video,
            "/media/sample.mp4",
            start,
            end,
        );
        c.timeline_offset_ms = offset;
        c.speed = speed;
        c
    }

    #[test]
    fn timecode_formats_and_parses() {
        assert_eq!(format_timecode(3_723_456, 30), "01:02:03.456");
        assert_eq!(parse_timecode("01:02:03.456"), Some(3_723_456));
        assert_eq!(parse_timecode("0:05"), Some(5_000));
        assert_eq!(parse_timecode("5"), Some(5_000));
        assert_eq!(parse_timecode("bad"), None);
        assert_eq!(parse_timecode("00:00:01,500"), Some(1_500));
    }

    #[test]
    fn frame_snapping_rounds_to_nearest_frame() {
        // 30fps → 1프레임 = 33.33ms
        assert_eq!(snap_to_frame(10, 30), 0);
        assert_eq!(snap_to_frame(20, 30), 33);
        assert_eq!(snap_to_frame(40, 30), 33);
        assert_eq!(snap_to_frame(1_000, 30), 1_000);
        assert_eq!(frame_index(1_000, 30), 30);
    }

    #[test]
    fn frame_timecode_uses_drop_free_frames() {
        assert_eq!(format_frame_timecode(1_000, 30), "00:00:01:00");
        assert_eq!(format_frame_timecode(1_033, 30), "00:00:01:01");
    }

    #[test]
    fn split_point_respects_speed() {
        let clip = clip(0, 0, 4_000, 2.0); // 타임라인 2000ms 차지
        let point = split_point(&clip, 1_000).expect("split");
        assert_eq!(point.source_ms, 2_000);
        assert_eq!(point.right_offset_ms, 1_000);
    }

    #[test]
    fn split_point_rejects_edges() {
        let clip = clip(1_000, 0, 4_000, 1.0);
        assert!(split_point(&clip, 1_000).is_err());
        assert!(split_point(&clip, 5_000).is_err());
        assert!(split_point(&clip, 2_500).is_ok());
    }

    #[test]
    fn snap_targets_include_clip_edges() {
        let clips = vec![clip(0, 0, 1_000, 1.0), clip(1_000, 0, 2_000, 1.0)];
        let targets = snap_targets(&clips, 30);
        assert_eq!(targets, vec![0, 1_000, 3_000]);
        assert_eq!(snap_to_targets(1_010, &targets, 20), 1_000);
        assert_eq!(snap_to_targets(1_100, &targets, 20), 1_100);
    }

    #[test]
    fn text_clip_has_no_source_path_requirement() {
        let mut ids = IdSeq::default();
        let c = Clip::new_text(ids.mint_clip(), TextOverlay::new("안녕"), 1_500);
        assert!(c.validate().is_ok());
        assert_eq!(c.timeline_duration_ms(), 1_500);
        assert_eq!(c.source_time_at(100), 100);
        assert_eq!(
            ClipId::new(c.id.as_str()).as_str(),
            c.id.as_str(),
            "id round-trips through string"
        );
    }
}
