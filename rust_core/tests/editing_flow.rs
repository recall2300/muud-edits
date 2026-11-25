//! 편집 시나리오 통합 테스트.
//!
//! 실제 사용자 흐름(가져오기 → 자르기 → 분할 → 자막 → 되돌리기)을 그대로 실행하고,
//! 되돌리기/다시적용이 상태를 정확히 복원하는지 확인한다.

use muud_core::commands::EditCommand;
use muud_core::model::{ClipKind, Resolution, TextOverlay, TrackKind};
use muud_core::subtitles::SubtitlePatch;
use muud_core::Editor;

fn editor() -> Editor {
    Editor::blank("통합 테스트", Resolution::VERTICAL_1080P, 30)
}

fn editor_ref() -> Editor {
    Editor::blank("통합 테스트", Resolution::VERTICAL_1080P, 30)
}

fn tracks_json(editor: &Editor) -> serde_json::Value {
    serde_json::to_value(&editor.project().tracks).expect("tracks json")
}

fn subtitles_json(editor: &Editor) -> serde_json::Value {
    serde_json::to_value(&editor.project().subtitles).expect("subtitles json")
}

#[test]
fn full_editing_session_can_be_undone_and_redone_completely() {
    let mut editor = editor();
    let video = editor.project().tracks[0].id.clone();
    let audio = editor.project().tracks[1].id.clone();
    let overlay = editor.project().tracks[2].id.clone();

    let before_tracks = tracks_json(&editor);

    // 1) 영상 2개 + 음악 1개 가져오기
    let a = editor
        .add_media_clip_with_duration(&video, ClipKind::Video, "/media/a.mp4", 10_000, None)
        .expect("clip a");
    let b = editor
        .add_media_clip_with_duration(&video, ClipKind::Video, "/media/b.mp4", 6_000, None)
        .expect("clip b");
    editor
        .add_media_clip_with_duration(&audio, ClipKind::Audio, "/media/bgm.m4a", 30_000, Some(0))
        .expect("bgm");

    // 영상 트랙은 16초, 배경음악 트랙은 30초이므로 프로젝트 전체 길이는 30초.
    let video_track_duration = editor.project().tracks[0].duration_ms();
    assert_eq!(video_track_duration, 16_000);
    assert_eq!(
        editor.project().duration_ms(),
        30_000,
        "가장 긴 트랙이 전체 길이"
    );
    assert_eq!(editor.summary().clip_count, 3);

    // 2) 첫 클립 앞 2초 버리고, 두 번째 클립 시작 부분을 분할해 삭제
    editor
        .trim(&video, &a, Some(2_000), None)
        .expect("trim head");
    // b는 10초 지점에서 시작하므로 그 안쪽인 11초에서 분할한다.
    let b_tail = editor.split(&video, &b, 11_000).expect("split");
    editor.remove_clip(&video, &b_tail).expect("drop tail");

    // 3) 텍스트 오버레이 + 자동 자막
    editor
        .add_text_clip(&overlay, TextOverlay::new("오픈"), 1_200, 0)
        .expect("text");
    editor
        .add_auto_subtitles(vec![
            (0, 900, "시작".into(), Some(0.9)),
            (900, 2_000, "다음".into(), Some(0.8)),
        ])
        .expect("auto subtitles");

    // 4) 자막 수정 + 볼륨 조절
    let subtitle_id = editor.project().subtitles.items[0].id.clone();
    editor
        .update_subtitle(
            &subtitle_id,
            SubtitlePatch {
                text: Some("시작!".into()),
                ..Default::default()
            },
        )
        .expect("fix subtitle");
    editor
        .set_volume(&audio, &editor.project().tracks[1].clips[0].id.clone(), 0.6)
        .expect("volume");

    // 5) 배속 변경은 겹침을 일으키지 않아야 한다(클립이 짧아짐)
    editor.set_speed(&video, &a, 2.0).expect("speed up");

    let edited_tracks = tracks_json(&editor);
    let edited_subtitles = subtitles_json(&editor);
    assert_ne!(before_tracks, edited_tracks);

    // 6) 모두 되돌리기
    while editor.can_undo() {
        editor.undo().expect("undo").expect("step");
    }
    assert_eq!(tracks_json(&editor), before_tracks, "트랙 상태가 원점으로");
    assert_eq!(subtitles_json(&editor), subtitles_json(&editor_ref()));
    assert_eq!(editor.project().duration_ms(), 0);

    // 7) 모두 다시 적용
    while editor.can_redo() {
        editor.redo().expect("redo").expect("step");
    }
    assert_eq!(
        tracks_json(&editor),
        edited_tracks,
        "다시 적용하면 같은 상태"
    );
    assert_eq!(subtitles_json(&editor), edited_subtitles);
}

#[test]
fn split_then_move_then_join_is_consistent() {
    let mut editor = editor();
    let video = editor.project().tracks[0].id.clone();
    let clip = editor
        .add_media_clip_with_duration(&video, ClipKind::Video, "/media/a.mp4", 5_000, None)
        .expect("clip");

    let right = editor.split(&video, &clip, 2_000).expect("split");
    assert_eq!(editor.project().tracks[0].clips.len(), 2);

    // 오른쪽 조각을 다른 트랙으로 옮겨도 원본 트랙은 겹치지 않는다.
    let overlay = editor.add_track(TrackKind::Video).expect("track");
    editor
        .move_clip(&video, &right, Some(overlay.clone()), 2_500)
        .expect("move");

    let summary = editor.summary();
    assert_eq!(summary.track_count, 4);
    assert_eq!(summary.clip_count, 2);
    // 왼쪽 조각 0~2000ms, 옮긴 오른쪽 조각 2500~5500ms
    assert_eq!(editor.project().duration_ms(), 5_500);

    // 옮긴 조각을 지우고 되돌리기
    editor.remove_clip(&overlay, &right).expect("remove");
    assert_eq!(editor.summary().clip_count, 1);
    editor.undo().expect("undo").expect("step");
    assert_eq!(editor.summary().clip_count, 2);
}

#[test]
fn overlapping_edits_are_rejected_without_changing_state() {
    let mut editor = editor();
    let video = editor.project().tracks[0].id.clone();
    let a = editor
        .add_media_clip_with_duration(&video, ClipKind::Video, "/a.mp4", 3_000, Some(0))
        .expect("a");
    editor
        .add_media_clip_with_duration(&video, ClipKind::Video, "/b.mp4", 3_000, None)
        .expect("b");

    let before = serde_json::to_string(&editor.project().tracks).expect("json");
    let undo_depth = editor.summary().undo_depth;

    let err = editor
        .move_clip(&video, &a, None, 2_000)
        .expect_err("이동하면 겹친다");
    assert_eq!(err.code(), "overlap");
    assert_eq!(
        serde_json::to_string(&editor.project().tracks).expect("json"),
        before,
        "실패한 커맨드는 상태를 바꾸지 않는다"
    );
    assert_eq!(editor.summary().undo_depth, undo_depth);
}

#[test]
fn raw_command_stream_from_dart_style_json_works() {
    let mut editor = editor();
    let video = editor.project().tracks[0].id.clone();

    // Dart가 보낼 법한 JSON을 그대로 커맨드로 만든다.
    let json = format!(
        r#"{{
            "type": "add_clip",
            "track_id": "{}",
            "clip": {{
                "id": "clp-7001",
                "source_path": "/media/from-dart.mp4",
                "kind": "video",
                "start_ms": 0,
                "end_ms": 4000,
                "timeline_offset_ms": 0
            }}
        }}"#,
        video
    );
    let command: EditCommand = serde_json::from_str(&json).expect("parse command");
    editor.apply(command).expect("apply");

    assert_eq!(editor.summary().clip_count, 1);
    assert_eq!(editor.project().duration_ms(), 4_000);

    // 같은 JSON으로 분할도 가능
    let split = format!(
        r#"{{"type":"split_clip","track_id":"{}","clip_id":"clp-7001","at_timeline_ms":1500}}"#,
        video
    );
    let command: EditCommand = serde_json::from_str(&split).expect("parse split");
    editor.apply(command).expect("split");
    assert_eq!(editor.summary().clip_count, 2);
}

#[test]
fn track_operations_and_locking() {
    let mut editor = editor();
    let overlay = editor.add_track(TrackKind::Overlay).expect("track");
    assert!(editor
        .project()
        .track(&overlay)
        .map(|t| t.kind == TrackKind::Overlay)
        .unwrap_or(false));

    editor
        .apply(EditCommand::RenameTrack {
            track_id: overlay.clone(),
            name: "자막 바".into(),
        })
        .expect("rename");
    assert_eq!(editor.project().track(&overlay).unwrap().name, "자막 바");

    editor
        .apply(EditCommand::SetTrackState {
            track_id: overlay.clone(),
            muted: None,
            hidden: Some(true),
            locked: Some(true),
        })
        .expect("hide+lock");

    let clip_id = editor.project().tracks[2]
        .clips
        .first()
        .map(|c| c.id.clone());
    assert!(clip_id.is_none(), "overlay 1은 아직 비어 있다");
    assert!(editor.project().track(&overlay).unwrap().hidden);

    // 잠긴 트랙에는 편집 불가
    let err = editor
        .apply(EditCommand::AddClip {
            track_id: overlay.clone(),
            clip: {
                let mut c = muud_core::Clip::new_media(
                    muud_core::ClipId::new("clp-x"),
                    ClipKind::Video,
                    "/a.mp4",
                    0,
                    1_000,
                );
                c.timeline_offset_ms = 0;
                c
            },
        })
        .expect_err("locked");
    assert_eq!(err.code(), "track_locked");
}
