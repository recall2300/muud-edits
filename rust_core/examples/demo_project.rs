//! 코어 엔진 데모.
//!
//! 편집 시나리오를 코드로 실행해 보고, 결과 요약과 플랫폼별 내보내기 계획을
//! 출력한다. Rust 툴체인만 있으면 항상 같은 결과가 나온다(파일 I/O 외 부작용 없음).
//!
//! ```bash
//! cd rust_core && cargo run --example demo_project
//! ```

use std::path::PathBuf;

use muud_core::export::{Container, ExportSettings, HwAccel, VideoCodec};
use muud_core::model::{ClipKind, Resolution, TextOverlay, TrackKind};
use muud_core::platform::Platform;
use muud_core::subtitles::SubtitlePatch;
use muud_core::Editor;

fn main() {
    // 1) 숏폼 프로젝트 생성
    let mut editor = Editor::blank("상하이 마라톤 브이로그", Resolution::VERTICAL_1080P, 30);
    let video = editor.project().tracks[0].id.clone();
    let overlay = editor.project().tracks[2].id.clone();
    println!("▶ {}", editor.project().summary());

    // 2) 클립 2개 이어 붙이기(소스는 실제 파일이 없어도 모델/테스트는 동작한다)
    let intro = editor
        .add_media_clip_with_duration(&video, ClipKind::Video, "/media/IMG_0412.MOV", 12_000, None)
        .expect("intro clip");

    // 3) 인트로를 0.8x 슬로모션으로(길어지므로 뒤 클립을 붙이기 전에 바꿔야 겹치지 않는다)
    editor.set_speed(&video, &intro, 0.8).expect("speed");

    // 4) 브이롤을 이어 붙이고(자동으로 인트로 끝에), 앞부분 2초 잘라내기
    let broll = editor
        .add_media_clip_with_duration(&video, ClipKind::Video, "/media/IMG_0419.MOV", 8_000, None)
        .expect("broll clip");
    editor
        .trim(&video, &broll, Some(2_000), None)
        .expect("trim head");

    // 5) 브이롤을 3초 지점에서 분할하고 뒷부분 삭제
    let tail = editor.split(&video, &broll, 18_000).expect("split");
    editor.remove_clip(&video, &tail).expect("drop tail");

    // 6) 오버레이 텍스트
    let mut title = TextOverlay::new("상하이, 42.195km");
    title.size_px = 96.0;
    editor
        .add_text_clip(&overlay, title, 2_500, 500)
        .expect("title");

    // 7) 자동 자막(Whisper 결과를 흉내)
    editor
        .add_auto_subtitles(vec![
            (0, 1_800, "드디어 출발선".to_string(), Some(0.97)),
            (1_800, 4_200, "페이스 5분 30초 유지".to_string(), Some(0.93)),
        ])
        .expect("auto subs");
    let first_sub = editor.project().subtitles.items[0].id.clone();
    editor
        .update_subtitle(
            &first_sub,
            SubtitlePatch {
                text: Some("드디어 출발선!".into()),
                ..Default::default()
            },
        )
        .expect("fix subtitle");

    // 7) 결과
    let total = editor.project().duration_ms();
    println!(
        "▶ 편집 후 길이: {}ms ({})",
        total,
        editor.summary().duration_label
    );
    println!("▶ 클립 수: {}", editor.summary().clip_count);
    println!("▶ 자막 수: {}", editor.summary().subtitle_count);

    // 8) 되돌리기 한 번(자막 수정 취소) → 다시 적용
    editor.undo().expect("undo").expect("something to undo");
    println!(
        "▶ undo 후 자막 첫 줄: {:?}",
        editor
            .project()
            .subtitles
            .items
            .first()
            .map(|i| i.text.clone())
    );
    editor.redo().expect("redo").expect("something to redo");

    // 9) 플랫폼별 내보내기 계획
    let mut settings = ExportSettings::for_project(Resolution::VERTICAL_1080P, 30);
    settings.codec = VideoCodec::H264;
    settings.container = Container::Mp4;
    settings.hardware = HwAccel::Auto;

    println!("\n▶ 플랫폼별 내보내기 계획");
    for platform in Platform::ALL {
        let plan = settings.plan(platform, "/media/timeline.mov", "/out/shanghai.mp4");
        println!("  - {}: {}", platform.id(), plan.summary());
        println!("    ffmpeg: {}", plan.ffmpeg_command);
    }

    // 9-1) 결정적 렌더 그래프(네이티브 엔진의 입력)
    println!("\n▶ 렌더 그래프");
    for platform in [Platform::MacOs, Platform::Android] {
        let graph =
            muud_core::render_plan::RenderGraph::compile(editor.project(), &settings, platform)
                .expect("render graph");
        println!("  - {}: {}", platform.id(), graph.summary());
        println!("    digest: {}", graph.graph_digest);
    }

    // 10) 저장/불러오기 왕복
    let out_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target/demo");
    std::fs::create_dir_all(&out_dir).expect("create demo dir");
    let project_path = out_dir.join("shanghai.muudproj");
    editor.save_to(&project_path).expect("save project");
    let reloaded = Editor::load_from(&project_path).expect("load project");
    assert_eq!(reloaded.project(), editor.project(), "저장/불러오기 왕복");
    println!(
        "\n▶ 저장 완료: {:?} ({} bytes)",
        project_path,
        std::fs::metadata(&project_path)
            .map(|m| m.len())
            .unwrap_or(0)
    );

    if let Some(path) = editor.save_srt(out_dir.join("shanghai.srt")).expect("srt") {
        println!("▶ 자막 저장: {path}");
    }

    // 11) 검증
    let issues = editor.project().validate();
    println!(
        "▶ 불변식 검증: {}",
        if issues.is_empty() {
            "통과".to_string()
        } else {
            issues.join(", ")
        }
    );
    println!("▶ 2단계 빌드 확인용: 새 오버레이 트랙 추가");
    let _ = editor.add_track(TrackKind::Overlay);
    println!("▶ 최종: {}", editor.project().summary());
}
