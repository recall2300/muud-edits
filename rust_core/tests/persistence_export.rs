//! 저장/불러오기와 내보내기 계획 통합 테스트.

use muud_core::export::{AudioCodec, Container, ExportSettings, HwAccel, VideoCodec};
use muud_core::model::{ClipKind, Resolution};
use muud_core::platform::Platform;
use muud_core::{Editor, SCHEMA_VERSION};

#[test]
fn project_survives_disk_roundtrip_with_unicode_paths() {
    let dir = std::env::temp_dir().join("muud-edits-통합-테스트");
    std::fs::create_dir_all(&dir).expect("dir");
    let path = dir.join(format!("상하이 브이로그 {}.muudproj", std::process::id()));

    let mut editor = Editor::blank("상하이 브이로그 🎬", Resolution::VERTICAL_1080P, 30);
    let video = editor.project().tracks[0].id.clone();
    editor
        .add_media_clip_with_duration(&video, ClipKind::Video, "/media/출발선.MOV", 9_000, None)
        .expect("clip");
    editor
        .add_subtitle(Some(0), Some(1_500), "출발!")
        .expect("sub");
    editor.save_to(&path).expect("save");

    let text = std::fs::read_to_string(&path).expect("read");
    assert!(text.contains("schema_version"));
    assert!(text.contains("상하이 브이로그"));

    let mut reloaded = Editor::load_from(&path).expect("load");
    assert_eq!(reloaded.project(), editor.project());
    assert!(!reloaded.dirty, "불러온 직후에는 dirty가 아니다");
    assert_eq!(reloaded.summary().duration_ms, 9_000);

    // 다시 편집하면 dirty가 켜진다.
    let video = reloaded.project().tracks[0].id.clone();
    reloaded
        .add_media_clip_with_duration(&video, ClipKind::Video, "/media/도착.MOV", 4_000, None)
        .expect("clip2");
    assert!(reloaded.dirty);
    assert_eq!(reloaded.summary().duration_ms, 13_000);

    let _ = std::fs::remove_file(&path);
}

#[test]
fn saved_json_has_current_schema_and_is_pretty() {
    let editor = Editor::blank("스키마", Resolution::LANDSCAPE_1080P, 24);
    let json = editor.to_json().expect("json");
    assert!(json.contains(&format!("\"schema_version\": {SCHEMA_VERSION}")));
    assert!(json.contains("\n  "), "사람이 읽을 수 있는 pretty JSON");

    let parsed: serde_json::Value = serde_json::from_str(&json).expect("parse");
    assert_eq!(parsed["fps"], 24);
    assert_eq!(parsed["export"]["watermark"], false);
    assert_eq!(parsed["export"]["resolution"]["width"], 1920);
}

#[test]
fn empty_timeline_exports_zero_length_but_valid_plan() {
    let editor = Editor::blank("빈 프로젝트", Resolution::VERTICAL_1080P, 30);
    assert_eq!(editor.project().duration_ms(), 0);
    let plan = editor
        .project()
        .export
        .plan(Platform::MacOs, "/in.mov", "/out.mp4");
    assert!(plan.ffmpeg_command.contains("h264_videotoolbox"));
    assert!(!plan.has_watermark_filter());
}

#[test]
fn export_matrix_never_adds_watermark() {
    let mut settings = ExportSettings::for_project(Resolution::VERTICAL_1080P, 30);
    for platform in Platform::ALL {
        for (codec, container) in [
            (VideoCodec::H264, Container::Mp4),
            (VideoCodec::Hevc, Container::Mp4),
            (VideoCodec::ProRes, Container::Mov),
            (VideoCodec::Av1, Container::Mp4),
        ] {
            settings.codec = codec;
            settings.container = container;
            settings.audio_codec = if container == Container::Mov && codec == VideoCodec::ProRes {
                AudioCodec::PcmS16Le
            } else {
                AudioCodec::Aac
            };
            assert!(
                settings.validate_for(platform).is_ok(),
                "{:?}/{:?} 검증 실패",
                platform.id(),
                codec
            );
            let plan = settings.plan(platform, "/in.mov", "/out.mp4");
            assert!(!plan.watermark);
            assert!(!plan.has_watermark_filter());
            assert!(!plan.encoder.name.is_empty());
        }
    }
}

#[test]
fn webm_opus_plan_is_valid_for_all_platforms() {
    let mut settings = ExportSettings::for_project(Resolution::VERTICAL_1080P, 60);
    settings.codec = VideoCodec::Vp9;
    settings.container = Container::WebM;
    settings.audio_codec = AudioCodec::Opus;
    settings.fps = 60;
    settings.video_bitrate_kbps = 6_000;

    for platform in Platform::ALL {
        assert!(settings.validate_for(platform).is_ok());
        let plan = settings.plan(platform, "/in.mov", "/out.webm");
        assert_eq!(plan.output_extension, "webm");
        assert!(plan.ffmpeg_command.contains("-c:a libopus"));
        assert!(plan.ffmpeg_command.contains("-r 60"));
    }
}

#[test]
fn hardware_request_is_honoured_or_reported() {
    let mut settings = ExportSettings::for_project(Resolution::VERTICAL_1080P, 30);
    settings.hardware = HwAccel::VideoToolbox;

    let mac = settings.encoder_for(Platform::MacOs);
    assert!(mac.hardware);
    assert_eq!(mac.name, "h264_videotoolbox");

    let android = settings.encoder_for(Platform::Android);
    assert!(!android.hardware, "안드로이드에 VideoToolbox는 없다");
    assert!(android.notes.contains("폴백"));
    assert!(settings.validate_for(Platform::Android).is_err());
}
