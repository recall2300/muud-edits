//! # rust_core — muud-edits 코어 엔진
//!
//! Flutter UI와 플랫폼 미디어 파이프라인 사이의 "편집 도메인"을 담당한다.
//! 이 크레이트는 렌더링이나 디코딩을 직접 하지 않고, 다음을 소유한다.
//!
//! * [`model`] — 프로젝트/트랙/클립/자막/내보내기 설정 데이터 모델
//! * [`timeline`] — 타임라인 시간 계산(스플릿 지점, 프레임 양자화, 재생 위치 조회)
//! * [`commands`] — 되돌리기 가능한 편집 커맨드와 히스토리 스택
//! * [`editor`] — UI가 호출하는 편집기 파사드(적용/되돌리기/다시적용)
//! * [`project_io`] — `.muudproj` JSON 저장/불러오기와 스키마 버전 관리
//! * [`export`] / [`platform`] — 플랫폼별 인코더 선택과 ffmpeg 인자 계획
//! * [`render_plan`] — 타임라인을 결정적 렌더 그래프(RenderGraph)로 컴파일
//! * [`progress`] — 내보내기 진행률/취소 상태 기계(ExportProgress, ExportJob)
//! * [`probe`] — 플랫폼 미디어 프로브 결과 수신/검증(MediaProbeInfo)
//! * [`bridge`] — flutter_rust_bridge가 노출하는 얇은 JSON 인터페이스
//!
//! 설계 원칙은 `ARCHITECTURE.md` 참고. 요약하면,
//! 모든 시간은 **정수 밀리초**(`i64`)이고, 편집은 **커맨드**로만 일어나며,
//! 각 커맨드는 자신의 역 커맨드를 돌려주므로 undo/redo가 대칭적으로 동작한다.

// 코어 로직은 unsafe 없이 작성한다. `forbid` 대신 `deny` 를 쓰는 이유는
// flutter_rust_bridge 코드젠 글루(frb_generated.rs)만 예외로 허용하기 위해서다.
#![deny(unsafe_code)]

pub mod bridge;
pub mod commands;
pub mod editor;
pub mod error;
pub mod export;
pub mod ids;
pub mod model;
pub mod platform;
pub mod probe;
pub mod progress;
pub mod project_io;
pub mod render_plan;
pub mod subtitles;
pub mod timeline;

// flutter_rust_bridge 코드젠 글루 (Dart ↔ Rust FFI). 생성 파일은 직접 고치지 않는다.
// `dart run flutter_rust_bridge_codegen generate` 로 다시 만든다.
#[allow(unsafe_code)]
mod frb_generated;

pub use commands::{AppliedCommand, CommandOutcome, EditCommand, History};
pub use editor::Editor;
pub use error::{EditError, ExportError, ProjectIoError};
pub use export::{AudioCodec, Container, ExportSettings, HwAccel, VideoCodec};
pub use ids::{ClipId, SubtitleId, TrackId};
pub use model::{
    Clip, ClipKind, NormalizedAnchor, Project, Resolution, TextAlign, TextOverlay, Track, TrackKind,
};
pub use platform::{Platform, PlatformCapabilities};
pub use probe::{MediaProbeInfo, ProbedMediaType};
pub use progress::{ExportJob, ExportJobEvent, ExportJobState, ExportProgress};
pub use project_io::SCHEMA_VERSION;
pub use render_plan::{AudioMixSegment, RenderGraph, RenderSegment, SubtitleBurnIn};
pub use subtitles::{SubtitleItem, SubtitlePatch, SubtitleStyle, SubtitleTrack};

/// 코어 엔진 버전. 브리지에서 UI가 호환성 확인에 사용한다.
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// 현재 시각(ms, Unix epoch). 실패하면 0.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
