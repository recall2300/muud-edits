//! 내보내기 작업의 진행률/취소 상태 모델.
//!
//! ## 왜 코어에 두는가
//! 네이티브 인코더는 자기 진행률을 콜백/이벤트로 알려 준다. 플랫폼마다 단위가
//! 다르다(AVAssetExportSession은 `progress` 0.0~1.0, MediaCodec은 프레임 수,
//! ffmpeg는 `frame=`/`out_time_us=`). 이 모듈은 그 이벤트를 **하나의 상태 기계**로
//! 정규화한다. UI는 [`ExportProgress::percent`]만 보면 되고, 취소 규칙은 한 곳에만 있다.
//!
//! ## 상태 기계
//! ```text
//! Queued ──▶ Preparing ──▶ Rendering ──▶ Finalizing ──▶ Completed
//!   │            │             │              │
//!   └────────────┴─────────────┴──────────────┴────────▶ Canceled (요청 후 확정)
//!                              └────────────────────────▶ Failed
//! ```
//! * `Completed`/`Canceled`/`Failed`는 **종료 상태**다. 이후 이벤트는 무시된다.
//! * 취소는 **요청**과 **확정**이 나뉜다. 렌더 중에는 진행률이 계속 올 수 있으므로
//!   요청만으로 상태를 끝내지 않는다. 네이티브 레이어가 `confirm_canceled`를 보내야
//!   `Canceled`가 된다(파일 정리까지 끝난 시점).
//! * 시간(ms)은 호출자가 넘긴다. 테스트와 재현성을 위해 내부에서 시계를 읽지 않는다.

use serde::{Deserialize, Serialize};

/// 내보내기 작업 상태.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExportJobState {
    /// 큐에 들어감(아직 파일/인코더 준비 전).
    Queued,
    /// 소스 확인, 렌더 그래프 준비, 인코더 초기화.
    Preparing,
    /// 프레임 렌더/인코딩 중.
    Rendering,
    /// 컨테이너 마무리(faststart, mux flush).
    Finalizing,
    /// 완료.
    Completed,
    /// 사용자 취소가 확정됨.
    Canceled,
    /// 실패.
    Failed,
}

impl ExportJobState {
    pub fn as_str(self) -> &'static str {
        match self {
            ExportJobState::Queued => "queued",
            ExportJobState::Preparing => "preparing",
            ExportJobState::Rendering => "rendering",
            ExportJobState::Finalizing => "finalizing",
            ExportJobState::Completed => "completed",
            ExportJobState::Canceled => "canceled",
            ExportJobState::Failed => "failed",
        }
    }

    /// 더 이상 진행률/상태 변화를 받지 않는 상태.
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            ExportJobState::Completed | ExportJobState::Canceled | ExportJobState::Failed
        )
    }

    /// 취소 요청을 받을 수 있는 상태.
    pub fn can_cancel(self) -> bool {
        matches!(
            self,
            ExportJobState::Queued
                | ExportJobState::Preparing
                | ExportJobState::Rendering
                | ExportJobState::Finalizing
        )
    }

    /// UI에 그대로 보여 줄 한국어 라벨.
    pub fn label(self) -> &'static str {
        match self {
            ExportJobState::Queued => "대기 중",
            ExportJobState::Preparing => "준비 중",
            ExportJobState::Rendering => "렌더링 중",
            ExportJobState::Finalizing => "마무리 중",
            ExportJobState::Completed => "완료",
            ExportJobState::Canceled => "취소됨",
            ExportJobState::Failed => "실패",
        }
    }
}

/// UI가 그리는 진행률 스냅샷.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ExportProgress {
    pub state: ExportJobState,
    pub state_label: String,
    pub completed_frames: u64,
    pub total_frames: u64,
    /// 0.0~1.0.
    pub fraction: f32,
    /// 0.0~100.0 (소수 1자리).
    pub percent: f32,
    pub started_at_ms: i64,
    pub updated_at_ms: i64,
    pub elapsed_ms: i64,
    /// 남은 시간 추정(ms). 계산할 수 없으면 None.
    #[serde(default)]
    pub eta_ms: Option<i64>,
    /// 취소 요청이 접수되었는가(확정 전).
    pub cancel_requested: bool,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
}

impl ExportProgress {
    /// 아직 시작하지 않은 작업의 초기 스냅샷.
    pub fn initial(total_frames: u64, at_ms: i64) -> Self {
        Self {
            state: ExportJobState::Queued,
            state_label: ExportJobState::Queued.label().to_string(),
            completed_frames: 0,
            total_frames,
            fraction: 0.0,
            percent: 0.0,
            started_at_ms: at_ms,
            updated_at_ms: at_ms,
            elapsed_ms: 0,
            eta_ms: None,
            cancel_requested: false,
            message: None,
            error: None,
        }
    }

    pub fn is_terminal(&self) -> bool {
        self.state.is_terminal()
    }

    pub fn is_running(&self) -> bool {
        !self.state.is_terminal()
    }

    /// 진행률을 반영해 파생 필드(fraction/percent/eta)를 다시 계산한다.
    pub fn refresh(&mut self, now_ms: i64) {
        let total = self.total_frames;
        let done = self.completed_frames.min(total);
        self.completed_frames = done;
        self.fraction = match self.state {
            ExportJobState::Completed => 1.0,
            _ if total == 0 => 0.0,
            _ => (done as f64 / total as f64).clamp(0.0, 1.0) as f32,
        };
        self.percent = ((self.fraction * 1000.0).round()) / 10.0;
        self.state_label = self.state.label().to_string();
        self.updated_at_ms = now_ms;
        self.elapsed_ms = (now_ms - self.started_at_ms).max(0);
        self.eta_ms = if self.is_running() && self.fraction > 0.001 && self.fraction < 0.999 {
            let remaining = (1.0 - self.fraction) as f64 / self.fraction as f64;
            Some((self.elapsed_ms as f64 * remaining).round() as i64)
        } else {
            None
        };
    }
}

impl Default for ExportProgress {
    fn default() -> Self {
        Self::initial(0, 0)
    }
}

/// 진행률 이벤트(브리지에서 JSON으로 들어온다).
///
/// ```json
/// {"type":"stage","state":"rendering"}
/// {"type":"progress","completed_frames":120}
/// {"type":"cancel_request"}
/// {"type":"canceled"}
/// {"type":"completed"}
/// {"type":"failed","message":"인코더 초기화 실패"}
/// ```
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ExportJobEvent {
    /// 단계 전환.
    Stage {
        state: ExportJobState,
        #[serde(default)]
        at_ms: Option<i64>,
    },
    /// 진행률 갱신(프레임 단위).
    Progress {
        completed_frames: u64,
        #[serde(default)]
        at_ms: Option<i64>,
    },
    /// 사용자가 취소를 눌렀다. 네이티브 레이어에 취소를 전달해야 한다.
    CancelRequest {
        #[serde(default)]
        at_ms: Option<i64>,
    },
    /// 네이티브 레이어가 취소를 확정했다(파일 정리 완료).
    Canceled {
        #[serde(default)]
        at_ms: Option<i64>,
    },
    /// 완료.
    Completed {
        #[serde(default)]
        at_ms: Option<i64>,
    },
    /// 실패.
    Failed {
        message: String,
        #[serde(default)]
        at_ms: Option<i64>,
    },
}

impl ExportJobEvent {
    pub fn at_ms(&self) -> Option<i64> {
        match self {
            ExportJobEvent::Stage { at_ms, .. }
            | ExportJobEvent::Progress { at_ms, .. }
            | ExportJobEvent::CancelRequest { at_ms }
            | ExportJobEvent::Canceled { at_ms }
            | ExportJobEvent::Completed { at_ms }
            | ExportJobEvent::Failed { at_ms, .. } => *at_ms,
        }
    }
}

/// 내보내기 작업 하나. 직렬화해서 Dart가 들고 다닌다(코어는 상태를 저장하지 않는다).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ExportJob {
    pub job_id: String,
    pub progress: ExportProgress,
}

impl ExportJob {
    /// 새 작업. 실제 시작은 `Stage{Preparing}` 이벤트로 알린다.
    pub fn new(job_id: impl Into<String>, total_frames: u64, at_ms: i64) -> Self {
        Self {
            job_id: job_id.into(),
            progress: ExportProgress::initial(total_frames, at_ms),
        }
    }

    pub fn total_frames(&self) -> u64 {
        self.progress.total_frames
    }

    pub fn state(&self) -> ExportJobState {
        self.progress.state
    }

    pub fn is_terminal(&self) -> bool {
        self.progress.state.is_terminal()
    }

    /// 취소 요청 가능 여부(종료 상태면 false).
    pub fn can_cancel(&self) -> bool {
        self.progress.state.can_cancel() && !self.progress.cancel_requested
    }

    /// 이벤트 하나를 적용한다. 종료 상태에서는 아무것도 바꾸지 않고 `false`.
    pub fn apply(&mut self, event: &ExportJobEvent, now_ms: i64) -> bool {
        let at = event.at_ms().unwrap_or(now_ms);
        match event {
            ExportJobEvent::Stage { state, .. } => self.set_state(*state, at),
            ExportJobEvent::Progress {
                completed_frames, ..
            } => self.advance_to(*completed_frames, at),
            ExportJobEvent::CancelRequest { .. } => self.request_cancel(at),
            ExportJobEvent::Canceled { .. } => self.confirm_canceled(at),
            ExportJobEvent::Completed { .. } => self.finish(at),
            ExportJobEvent::Failed { message, .. } => self.fail(message, at),
        }
    }

    /// 단계 전환. 뒤로 가는 전환(Completed → Rendering 등)은 무시한다.
    pub fn set_state(&mut self, state: ExportJobState, at_ms: i64) -> bool {
        if self.progress.state.is_terminal() {
            return false;
        }
        if self.progress.cancel_requested && state != ExportJobState::Canceled {
            // 취소 요청 후에는 확정만 받는다.
            return false;
        }
        if !allowed_transition(self.progress.state, state) {
            return false;
        }
        self.progress.state = state;
        if state.is_terminal() {
            self.progress.cancel_requested = matches!(state, ExportJobState::Canceled);
        }
        self.progress.refresh(at_ms);
        true
    }

    /// 진행률 갱신. 완료 프레임이 처음 들어오면 자동으로 `Rendering`으로 올린다.
    pub fn advance_to(&mut self, completed_frames: u64, at_ms: i64) -> bool {
        if self.progress.state.is_terminal() || self.progress.cancel_requested {
            return false;
        }
        let clamped = completed_frames.min(self.progress.total_frames);
        self.progress.completed_frames = clamped;
        if clamped > 0
            && matches!(
                self.progress.state,
                ExportJobState::Queued | ExportJobState::Preparing
            )
        {
            self.progress.state = ExportJobState::Rendering;
        }
        if self.progress.total_frames > 0 && clamped >= self.progress.total_frames {
            // 마지막 프레임까지 갔어도 완료는 네이티브가 확정한다(파일 마감 전).
            self.progress.state = ExportJobState::Finalizing;
        }
        self.progress.refresh(at_ms);
        true
    }

    /// 취소 요청. 시작 전이면 즉시 확정, 진행 중이면 네이티브 확정을 기다린다.
    pub fn request_cancel(&mut self, at_ms: i64) -> bool {
        if !self.progress.state.can_cancel() || self.progress.cancel_requested {
            return false;
        }
        self.progress.cancel_requested = true;
        self.progress.message = Some("취소 요청됨".to_string());
        if matches!(
            self.progress.state,
            ExportJobState::Queued | ExportJobState::Preparing
        ) {
            self.progress.state = ExportJobState::Canceled;
        }
        self.progress.refresh(at_ms);
        true
    }

    /// 네이티브 레이어의 취소 확정.
    pub fn confirm_canceled(&mut self, at_ms: i64) -> bool {
        if !self.progress.cancel_requested && self.progress.state != ExportJobState::Canceled {
            return false;
        }
        if self.progress.state == ExportJobState::Completed
            || self.progress.state == ExportJobState::Failed
        {
            return false;
        }
        self.progress.state = ExportJobState::Canceled;
        self.progress.message = Some("취소됨".to_string());
        self.progress.refresh(at_ms);
        true
    }

    /// 완료 확정.
    pub fn finish(&mut self, at_ms: i64) -> bool {
        if self.progress.state.is_terminal() || self.progress.cancel_requested {
            return false;
        }
        self.progress.completed_frames = self.progress.total_frames;
        self.progress.state = ExportJobState::Completed;
        self.progress.message = Some("완료".to_string());
        self.progress.refresh(at_ms);
        true
    }

    /// 실패 처리. 이미 종료 상태면 무시.
    pub fn fail(&mut self, message: &str, at_ms: i64) -> bool {
        if self.progress.state.is_terminal() {
            return false;
        }
        self.progress.state = ExportJobState::Failed;
        self.progress.error = Some(message.to_string());
        self.progress.refresh(at_ms);
        true
    }

    /// UI 한 줄 요약.
    pub fn summary(&self) -> String {
        format!(
            "{} · {:.1}% ({}/{} frames) · {}",
            self.progress.state_label,
            self.progress.percent,
            self.progress.completed_frames,
            self.progress.total_frames,
            self.job_id
        )
    }
}

/// 허용되는 단계 전환. 같은 상태로의 재진입은 허용한다.
fn allowed_transition(from: ExportJobState, to: ExportJobState) -> bool {
    use ExportJobState::*;
    if from == to {
        return true;
    }
    match (from, to) {
        (Queued, Preparing | Rendering | Canceled | Failed) => true,
        (Preparing, Rendering | Finalizing | Canceled | Failed) => true,
        (Rendering, Finalizing | Canceled | Failed) => true,
        (Finalizing, Completed | Canceled | Failed) => true,
        (Completed | Canceled | Failed, _) => false,
        // 뒤로 가는 전환은 받지 않는다.
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job() -> ExportJob {
        ExportJob::new("job-1", 300, 1_000)
    }

    #[test]
    fn initial_state_is_queued_and_zero() {
        let job = job();
        assert_eq!(job.state(), ExportJobState::Queued);
        assert_eq!(job.progress.percent, 0.0);
        assert_eq!(job.progress.total_frames, 300);
        assert!(job.can_cancel());
        assert_eq!(job.progress.state_label, "대기 중");
    }

    #[test]
    fn progress_moves_to_rendering_and_reports_eta() {
        let mut job = job();
        assert!(job.apply(
            &ExportJobEvent::Stage {
                state: ExportJobState::Preparing,
                at_ms: Some(1_200)
            },
            0
        ));
        assert!(job.advance_to(30, 3_200));
        assert_eq!(job.state(), ExportJobState::Rendering);
        assert_eq!(job.progress.percent, 10.0);
        // 2.2초(작업 생성 1초 → 3.2초)에 10% → 남은 90%는 약 19.8초.
        assert_eq!(job.progress.eta_ms, Some(19_800));
    }

    #[test]
    fn last_frame_moves_to_finalizing_not_completed() {
        let mut job = job();
        job.advance_to(300, 5_000);
        assert_eq!(job.state(), ExportJobState::Finalizing);
        assert_eq!(job.progress.percent, 100.0);
        assert!(job.finish(5_500));
        assert_eq!(job.state(), ExportJobState::Completed);
        assert_eq!(job.progress.fraction, 1.0);
        assert!(!job.can_cancel());
    }

    #[test]
    fn cancel_during_rendering_waits_for_confirm() {
        let mut job = job();
        job.advance_to(100, 2_000);
        assert!(job.apply(&ExportJobEvent::CancelRequest { at_ms: Some(2_100) }, 0));
        assert_eq!(job.state(), ExportJobState::Rendering);
        assert!(job.progress.cancel_requested);
        // 취소 요청 후 추가 진행/단계 전환은 무시.
        assert!(!job.advance_to(200, 2_200));
        assert!(!job.set_state(ExportJobState::Finalizing, 2_300));
        // 네이티브 확정.
        assert!(job.apply(&ExportJobEvent::Canceled { at_ms: Some(2_400) }, 0));
        assert_eq!(job.state(), ExportJobState::Canceled);
        assert!(job.is_terminal());
        assert!(!job.finish(2_500));
    }

    #[test]
    fn cancel_before_start_is_immediate() {
        let mut job = job();
        assert!(job.request_cancel(1_100));
        assert_eq!(job.state(), ExportJobState::Canceled);
        assert!(job.is_terminal());
        assert!(!job.can_cancel());
    }

    #[test]
    fn failure_keeps_progress_and_message() {
        let mut job = job();
        job.advance_to(120, 4_000);
        assert!(job.apply(
            &ExportJobEvent::Failed {
                message: "인코더 초기화 실패".into(),
                at_ms: Some(4_100)
            },
            0
        ));
        assert_eq!(job.state(), ExportJobState::Failed);
        assert_eq!(job.progress.completed_frames, 120);
        assert_eq!(job.progress.error.as_deref(), Some("인코더 초기화 실패"));
        assert!(!job.apply(&ExportJobEvent::Completed { at_ms: Some(4_200) }, 0));
    }

    #[test]
    fn terminal_states_are_final() {
        let mut job = job();
        job.finish(2_000);
        for event in [
            ExportJobEvent::Progress {
                completed_frames: 10,
                at_ms: Some(3_000),
            },
            ExportJobEvent::Stage {
                state: ExportJobState::Rendering,
                at_ms: Some(3_000),
            },
            ExportJobEvent::Failed {
                message: "늦은 실패".into(),
                at_ms: Some(3_000),
            },
        ] {
            assert!(!job.apply(&event, 0));
        }
        assert_eq!(job.state(), ExportJobState::Completed);
        assert_eq!(job.progress.completed_frames, 300);
    }

    #[test]
    fn progress_is_clamped_to_total() {
        let mut job = job();
        job.advance_to(9_999, 2_000);
        assert_eq!(job.progress.completed_frames, 300);
    }

    #[test]
    fn zero_frame_job_completes_without_nan() {
        let mut job = ExportJob::new("job-empty", 0, 0);
        assert!(job.finish(10));
        assert_eq!(job.state(), ExportJobState::Completed);
        assert_eq!(job.progress.fraction, 1.0);
        assert_eq!(job.progress.percent, 100.0);
        assert!(job.progress.eta_ms.is_none());
    }

    #[test]
    fn job_roundtrips_through_json() {
        let mut job = job();
        job.advance_to(150, 6_000);
        let json = serde_json::to_string(&job).expect("serialize");
        let back: ExportJob = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back, job);
        assert!(json.contains("\"rendering\""));
    }
}
