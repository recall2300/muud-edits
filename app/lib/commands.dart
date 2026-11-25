/// Rust 코어로 보내는 편집 커맨드 빌더.
///
/// 커맨드 스키마는 `rust_core/src/commands.rs`의 `EditCommand`와 1:1이다
/// (docs/BRIDGE_CONTRACT.md 참고). UI는 상태를 직접 고치지 않고
/// **항상 이 커맨드를 만들어 보낸다** — 그래야 되돌리기가 보장된다.
class Commands {
  const Commands._();

  /// 클립 분할.
  static Map<String, dynamic> splitClip({
    required String trackId,
    required String clipId,
    required int atMs,
  }) {
    return <String, dynamic>{
      'type': 'split_clip',
      'track_id': trackId,
      'clip_id': clipId,
      'at_timeline_ms': atMs,
    };
  }

  /// 트림(절대값 지정). null인 값은 그대로 둔다.
  static Map<String, dynamic> trimClip({
    required String trackId,
    required String clipId,
    int? startMs,
    int? endMs,
    int? offsetMs,
  }) {
    return <String, dynamic>{
      'type': 'trim_clip',
      'track_id': trackId,
      'clip_id': clipId,
      if (startMs != null) 'start_ms': startMs,
      if (endMs != null) 'end_ms': endMs,
      if (offsetMs != null) 'timeline_offset_ms': offsetMs,
    };
  }

  /// 클립 이동(트랙 지정은 선택).
  static Map<String, dynamic> moveClip({
    required String trackId,
    required String clipId,
    required int atMs,
    String? toTrackId,
  }) {
    return <String, dynamic>{
      'type': 'move_clip',
      'track_id': trackId,
      'clip_id': clipId,
      'to_track_id': toTrackId,
      'timeline_offset_ms': atMs,
    };
  }

  /// 클립 삭제.
  static Map<String, dynamic> removeClip({
    required String trackId,
    required String clipId,
  }) {
    return <String, dynamic>{
      'type': 'remove_clip',
      'track_id': trackId,
      'clip_id': clipId,
    };
  }

  /// 재생 속도(0.25 ~ 4.0).
  static Map<String, dynamic> setSpeed({
    required String trackId,
    required String clipId,
    required double speed,
  }) {
    return <String, dynamic>{
      'type': 'set_clip_speed',
      'track_id': trackId,
      'clip_id': clipId,
      'speed': speed,
    };
  }

  /// 클립 볼륨(0.0 ~ 2.0).
  static Map<String, dynamic> setVolume({
    required String trackId,
    required String clipId,
    required double volume,
  }) {
    return <String, dynamic>{
      'type': 'set_clip_volume',
      'track_id': trackId,
      'clip_id': clipId,
      'volume': volume,
    };
  }

  /// 불투명도(0.0 ~ 1.0).
  static Map<String, dynamic> setOpacity({
    required String trackId,
    required String clipId,
    required double opacity,
  }) {
    return <String, dynamic>{
      'type': 'set_clip_opacity',
      'track_id': trackId,
      'clip_id': clipId,
      'opacity': opacity,
    };
  }

  /// 클립 켜기/끄기.
  static Map<String, dynamic> setClipEnabled({
    required String trackId,
    required String clipId,
    required bool enabled,
  }) {
    return <String, dynamic>{
      'type': 'set_clip_enabled',
      'track_id': trackId,
      'clip_id': clipId,
      'enabled': enabled,
    };
  }

  /// 페이드 인/아웃.
  static Map<String, dynamic> setFades({
    required String trackId,
    required String clipId,
    required int fadeInMs,
    required int fadeOutMs,
  }) {
    return <String, dynamic>{
      'type': 'set_clip_fades',
      'track_id': trackId,
      'clip_id': clipId,
      'fade_in_ms': fadeInMs,
      'fade_out_ms': fadeOutMs,
    };
  }

  /// 트랙 음소거/숨김/잠금.
  static Map<String, dynamic> setTrackState({
    required String trackId,
    bool? muted,
    bool? hidden,
    bool? locked,
  }) {
    return <String, dynamic>{
      'type': 'set_track_state',
      'track_id': trackId,
      if (muted != null) 'muted': muted,
      if (hidden != null) 'hidden': hidden,
      if (locked != null) 'locked': locked,
    };
  }

  /// 텍스트 클립의 문구 교체(나머지 스타일은 코어 기본값 유지).
  static Map<String, dynamic> setClipText({
    required String trackId,
    required String clipId,
    required String content,
  }) {
    return <String, dynamic>{
      'type': 'set_clip_text',
      'track_id': trackId,
      'clip_id': clipId,
      'text': <String, dynamic>{'content': content},
    };
  }

  /// 자막 수정.
  static Map<String, dynamic> updateSubtitle({
    required String id,
    int? startMs,
    int? endMs,
    String? text,
  }) {
    return <String, dynamic>{
      'type': 'update_subtitle',
      'id': id,
      'patch': <String, dynamic>{
        if (startMs != null) 'start_ms': startMs,
        if (endMs != null) 'end_ms': endMs,
        if (text != null) 'text': text,
      },
    };
  }

  /// 자막 삭제.
  static Map<String, dynamic> removeSubtitle({required String id}) {
    return <String, dynamic>{'type': 'remove_subtitle', 'id': id};
  }
}
