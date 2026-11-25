//! 2단계 미디어 파이프라인 통합 시나리오.
//!
//! 편집 → 렌더 그래프 컴파일 → (플랫폼 이벤트를 흉내 낸) 진행률/취소 → 프로브 정규화.
//! 실제 미디어 파일 없이 코어 계약만 검증한다.

use muud_core::commands::EditCommand;
use muud_core::export::{AudioCodec, Container};
use muud_core::model::{ClipKind, Resolution};
use muud_core::platform::Platform;
use muud_core::probe::{MediaProbeInfo, ProbedMediaType};
use muud_core::progress::{ExportJob, ExportJobEvent, ExportJobState};
use muud_core::render_plan::RenderGraph;
use muud_core::Editor;

fn build_editor() -> Editor {
    let mut editor = Editor::blank("상하이 브이로그", Resolution::VERTICAL_1080P, 30);
    let video = editor.project().tracks.clone();
    let video_track = video[0].id.clone();
    let audio_track = video[1].id.clone();

    let intro = editor
        .add_media_clip_with_duration(
            &video_track,
            ClipKind::Video,
            "/media/IMG_0412.MOV",
            6_000,
            None,
        )
        .expect("intro");
    editor
        .apply(EditCommand::SetClipFades {
            track_id: video_track.clone(),
            clip_id: intro.clone(),
            fade_in_ms: 500,
            fade_out_ms: 500,
        })
        .expect("fade");
    editor
        .add_media_clip_with_duration(
            &video_track,
            ClipKind::Video,
            "/media/IMG_0419.MOV",
            4_000,
            None,
        )
        .expect("broll");
    editor
        .add_media_clip_with_duration(
            &audio_track,
            ClipKind::Audio,
            "/media/bgm.m4a",
            10_000,
            Some(0),
        )
        .expect("bgm");
    editor
        .add_subtitle(Some(500), Some(2_500), "드디어 출발선")
        .expect("subtitle");
    editor
}

#[test]
fn graph_layout_is_identical_across_platforms() {
    let editor = build_editor();
    let settings = editor.project().export.clone();
    let platforms = [
        Platform::MacOs,
        Platform::Windows,
        Platform::Android,
        Platform::Ios,
    ];

    let mut base: Option<(u64, i64, usize, usize, usize)> = None;
    for platform in platforms {
        let graph = RenderGraph::compile(editor.project(), &settings, platform).expect("graph");
        assert!(graph.validate().is_empty(), "{:?}", graph.validate());
        assert!(!graph.watermark);
        let layout = (
            graph.frame_count,
            graph.duration_ms,
            graph.segments.len(),
            graph.audio_segments.len(),
            graph.subtitles.items.len(),
        );
        match &base {
            None => base = Some(layout),
            Some(expected) => assert_eq!(&layout, expected, "{}", platform.id()),
        }
        assert_eq!(graph.platform, platform.id());
        assert_eq!(
            graph.segments,
            RenderGraph::compile(editor.project(), &settings, platform)
                .expect("again")
                .segments
        );
    }
    let (frames, duration, segments, audio, subtitles) = base.expect("layout");
    assert_eq!(duration, 10_000);
    assert_eq!(frames, 300);
    assert_eq!(segments, 2);
    assert_eq!(audio, 3);
    assert_eq!(subtitles, 1);
}

#[test]
fn graph_digest_is_stable_for_same_input() {
    let editor = build_editor();
    let settings = editor.project().export.clone();
    let first = RenderGraph::compile(editor.project(), &settings, Platform::Android).expect("a");
    let second = RenderGraph::compile(editor.project(), &settings, Platform::Android).expect("b");
    assert_eq!(first.graph_digest, second.graph_digest);
    assert_eq!(first, second);
}

#[test]
fn export_job_follows_native_events_through_cancel() {
    let editor = build_editor();
    let graph = RenderGraph::compile(editor.project(), &editor.project().export, Platform::MacOs)
        .expect("graph");
    let mut job = ExportJob::new("job-demo", graph.frame_count, 1_000);
    assert_eq!(job.state(), ExportJobState::Queued);

    job.apply(
        &ExportJobEvent::Stage {
            state: ExportJobState::Preparing,
            at_ms: Some(1_100),
        },
        0,
    );
    job.apply(
        &ExportJobEvent::Progress {
            completed_frames: graph.frame_count / 2,
            at_ms: Some(6_100),
        },
        0,
    );
    assert_eq!(job.state(), ExportJobState::Rendering);
    assert_eq!(job.progress.percent, 50.0);
    assert!(job.progress.eta_ms.unwrap_or(0) > 0);

    // 렌더 중 취소: 요청만으로는 끝나지 않는다.
    assert!(job.request_cancel(6_200));
    assert_eq!(job.state(), ExportJobState::Rendering);
    assert!(job.progress.cancel_requested);
    // 네이티브가 정리를 마치고 확정한다.
    assert!(job.confirm_canceled(6_400));
    assert_eq!(job.state(), ExportJobState::Canceled);
    assert!(job.is_terminal());
    assert!(!job.finish(6_500));
}

#[test]
fn export_job_completes_with_full_progress() {
    let editor = build_editor();
    let graph = RenderGraph::compile(
        editor.project(),
        &editor.project().export,
        Platform::Windows,
    )
    .expect("graph");
    let mut job = ExportJob::new("job-complete", graph.frame_count, 0);
    job.apply(
        &ExportJobEvent::Progress {
            completed_frames: graph.frame_count,
            at_ms: Some(2_000),
        },
        0,
    );
    assert_eq!(job.state(), ExportJobState::Finalizing);
    assert!(job.apply(&ExportJobEvent::Completed { at_ms: Some(2_500) }, 0));
    assert_eq!(job.state(), ExportJobState::Completed);
    assert_eq!(job.progress.percent, 100.0);
    assert_eq!(job.progress.completed_frames, graph.frame_count);
}

#[test]
fn platform_probe_shapes_normalize_to_same_clip() {
    let avfoundation = r#"{
        "path": "/media/IMG_0412.MOV", "duration_ms": 6000,
        "width": 1080, "height": 1920, "fps": 29.97,
        "has_video": true, "has_audio": true,
        "audio_channels": 2, "audio_sample_rate": 48000,
        "video_codec": "avc1", "source": "avfoundation"
    }"#;
    let android = r#"{
        "path": "/media/IMG_0412.MOV", "duration_ms": 6000,
        "width": 1080, "height": 1920, "fps": 30.0,
        "has_video": true, "has_audio": true,
        "rotation_degrees": 0, "source": "android-media"
    }"#;
    let ffprobe = r#"{
        "path": "/media/IMG_0412.MOV", "duration_ms": 6000,
        "width": 1080, "height": 1920, "fps": 30.0,
        "has_video": true, "has_audio": true,
        "source": "ffprobe"
    }"#;

    let a = MediaProbeInfo::from_json(avfoundation).expect("avfoundation");
    let b = MediaProbeInfo::from_json(android).expect("android");
    let c = MediaProbeInfo::from_json(ffprobe).expect("ffprobe");
    for info in [&a, &b, &c] {
        assert!(info.validate().is_ok());
        assert_eq!(info.media_type(), ProbedMediaType::Video);
        assert_eq!(info.clip_kind(), Some(ClipKind::Video));
        assert_eq!(info.suggested_end_ms(), Some(6_000));
        assert_eq!(info.width, 1080);
        assert_eq!(info.height, 1920);
    }
}

#[test]
fn graph_audio_gain_matches_track_and_clip_volume() {
    let editor = build_editor();
    let graph = RenderGraph::compile(editor.project(), &editor.project().export, Platform::Ios)
        .expect("graph");
    let bgm = graph
        .audio_segments
        .iter()
        .find(|segment| segment.source_path.ends_with("bgm.m4a"))
        .expect("bgm");
    // 페이드가 없으므로 게인은 트랙 게인(1.0) × 클립 볼륨(1.0).
    assert!((bgm.gain - 1.0).abs() < 1e-6);
    assert!((bgm.gain_at(500) - 1.0).abs() < 1e-6);
}

#[test]
fn export_range_and_codec_rules_survive_full_pipeline() {
    let editor = build_editor();
    let mut settings = editor.project().export.clone();
    settings.range = Some(muud_core::export::ExportRange {
        start_ms: 2_000,
        end_ms: 8_000,
    });
    settings.audio_codec = AudioCodec::Aac;
    settings.container = Container::Mp4;

    let graph =
        RenderGraph::compile(editor.project(), &settings, Platform::Android).expect("graph");
    assert_eq!(graph.duration_ms, 6_000);
    assert_eq!(graph.frame_count, 180);
    let first = &graph.segments[0];
    assert_eq!(first.render_start_ms, 0);
    assert_eq!(first.source_in_ms, 2_000);
    assert_eq!(graph.subtitles.items[0].render_start_ms, 0);
}
