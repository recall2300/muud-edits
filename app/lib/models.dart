import 'dart:convert';

/// Rust 브리지가 돌려준 구조화 오류 (`{ok:false, error:{code,message}}`).
///
/// [code]는 UI 분기용 안정 키다: `overlap`, `track_locked`, `empty_text`,
/// `watermark_not_allowed`, `bad_state` …
class BridgeException implements Exception {
  BridgeException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

// -----------------------------------------------------------------------------
// JSON 파싱 헬퍼 (브리지 응답은 모두 untyped JSON이다)
// -----------------------------------------------------------------------------

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((Object? k, Object? v) => MapEntry(k.toString(), v));
  }
  return const <String, dynamic>{};
}

List<Map<String, dynamic>> _mapList(Object? value) {
  if (value is List) {
    return value.map(_map).toList(growable: false);
  }
  return const <Map<String, dynamic>>[];
}

int _int(Object? value, [int fallback = 0]) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

double _double(Object? value, [double fallback = 0]) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? fallback;
  }
  return fallback;
}

bool _bool(Object? value, [bool fallback = false]) {
  if (value is bool) {
    return value;
  }
  return fallback;
}

String _string(Object? value, [String fallback = '']) {
  if (value is String) {
    return value;
  }
  if (value == null) {
    return fallback;
  }
  return value.toString();
}

// -----------------------------------------------------------------------------
// 모델
// -----------------------------------------------------------------------------

/// 브리지가 돌려준 편집기 상태 전체.
///
/// `raw`는 Rust로 그대로 되돌려 보내야 하는 원본 JSON이다(불변으로 취급).
/// 화면에 필요한 조각만 파싱해 두고, 변경은 항상 커맨드로 보낸다.
class EditorState {
  EditorState({
    required this.raw,
    required this.summary,
    required this.tracks,
    required this.subtitles,
  });

  final Map<String, dynamic> raw;
  final ProjectSummary summary;
  final List<TrackView> tracks;
  final List<SubtitleView> subtitles;

  String get name => summary.name;
  int get fps => summary.fps;
  int get durationMs => summary.durationMs;
  int get width => summary.width;
  int get height => summary.height;
  double get aspectRatio => height == 0 ? 9 / 16 : width / height;

  /// 브리지 응답(JSON 문자열)을 상태로 바꾼다.
  ///
  /// `{ok:false}`면 [BridgeException]을 던진다.
  static EditorState fromEnvelope(String text) {
    final Object? decoded = jsonDecode(text);
    final Map<String, dynamic> envelope = _map(decoded);
    if (envelope['ok'] == false) {
      final Map<String, dynamic> error = _map(envelope['error']);
      throw BridgeException(
        _string(error['code'], 'unknown'),
        _string(error['message'], '알 수 없는 오류가 발생했습니다'),
      );
    }

    final Map<String, dynamic> state = envelope.containsKey('state')
        ? _map(envelope['state'])
        : envelope;
    final Map<String, dynamic> project = _map(state['project']);
    final Map<String, dynamic> summaryJson = envelope.containsKey('summary')
        ? _map(envelope['summary'])
        : _map(project);

    return EditorState(
      raw: state,
      summary: ProjectSummary.fromJson(summaryJson),
      tracks: _mapList(project['tracks']).map(TrackView.fromJson).toList(),
      subtitles: _mapList(
        _map(project['subtitles'])['items'],
      ).map(SubtitleView.fromJson).toList(),
    );
  }

  /// 이 응답에서 발급된 id(있으면).
  static String? createdIdOf(String text) {
    final Map<String, dynamic> envelope = _map(jsonDecode(text));
    final Object? id = envelope['created_id'];
    return id is String ? id : null;
  }

  TrackView? trackById(String id) {
    for (final TrackView track in tracks) {
      if (track.id == id) {
        return track;
      }
    }
    return null;
  }

  /// 클립 id로 (트랙, 클립)을 찾는다.
  ({TrackView track, ClipView clip})? findClip(String clipId) {
    for (final TrackView track in tracks) {
      for (final ClipView clip in track.clips) {
        if (clip.id == clipId) {
          return (track: track, clip: clip);
        }
      }
    }
    return null;
  }

  /// 재생 헤드에 보여야 하는 텍스트 오버레이(위쪽 트랙 우선).
  List<ClipView> textClipsAt(int atMs) {
    final List<ClipView> result = <ClipView>[];
    for (final TrackView track in tracks.reversed) {
      if (track.hidden) {
        continue;
      }
      for (final ClipView clip in track.clips) {
        if (clip.kind == 'text' && clip.enabled && clip.contains(atMs)) {
          result.add(clip);
        }
      }
    }
    return result;
  }

  /// 재생 헤드에 보여야 하는 자막.
  String? subtitleAt(int atMs) {
    for (final SubtitleView item in subtitles) {
      if (atMs >= item.startMs && atMs < item.endMs) {
        return item.text;
      }
    }
    return null;
  }
}

/// 프로젝트 요약(Rust `ProjectSummary`).
class ProjectSummary {
  ProjectSummary({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.fps,
    required this.durationMs,
    required this.durationLabel,
    required this.trackCount,
    required this.clipCount,
    required this.subtitleCount,
    required this.canUndo,
    required this.canRedo,
    required this.dirty,
    required this.watermark,
    required this.undoLabel,
    required this.redoLabel,
    required this.undoDepth,
    required this.redoDepth,
    required this.filePath,
    required this.tracks,
  });

  final String id;
  final String name;
  final int width;
  final int height;
  final int fps;
  final int durationMs;
  final String durationLabel;
  final int trackCount;
  final int clipCount;
  final int subtitleCount;
  final bool canUndo;
  final bool canRedo;
  final bool dirty;
  final bool watermark;
  final String? undoLabel;
  final String? redoLabel;
  final int undoDepth;
  final int redoDepth;
  final String? filePath;
  final List<TrackSummary> tracks;

  static ProjectSummary fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> resolution = _map(json['resolution']);
    final String? filePath = json['file_path'] is String
        ? json['file_path'] as String
        : null;
    final String? undoLabel = json['undo_label'] is String
        ? json['undo_label'] as String
        : null;
    final String? redoLabel = json['redo_label'] is String
        ? json['redo_label'] as String
        : null;

    return ProjectSummary(
      id: _string(json['id']),
      name: _string(json['name'], '제목 없음'),
      width: _int(resolution['width'], 1080),
      height: _int(resolution['height'], 1920),
      fps: _int(json['fps'], 30),
      durationMs: _int(json['duration_ms']),
      durationLabel: _string(json['duration_label'], '00:00:00:00'),
      trackCount: _int(json['track_count']),
      clipCount: _int(json['clip_count']),
      subtitleCount: _int(json['subtitle_count']),
      canUndo: _bool(json['can_undo']),
      canRedo: _bool(json['can_redo']),
      dirty: _bool(json['dirty']),
      watermark: _bool(json['watermark']),
      undoLabel: undoLabel,
      redoLabel: redoLabel,
      undoDepth: _int(json['undo_depth']),
      redoDepth: _int(json['redo_depth']),
      filePath: filePath,
      tracks: _mapList(json['tracks']).map(TrackSummary.fromJson).toList(),
    );
  }
}

/// 트랙 한 줄 요약.
class TrackSummary {
  TrackSummary({
    required this.id,
    required this.name,
    required this.kind,
    required this.clipCount,
    required this.durationMs,
    required this.muted,
    required this.hidden,
    required this.locked,
  });

  final String id;
  final String name;
  final String kind;
  final int clipCount;
  final int durationMs;
  final bool muted;
  final bool hidden;
  final bool locked;

  static TrackSummary fromJson(Map<String, dynamic> json) {
    return TrackSummary(
      id: _string(json['id']),
      name: _string(json['name']),
      kind: _string(json['kind'], 'video'),
      clipCount: _int(json['clip_count']),
      durationMs: _int(json['duration_ms']),
      muted: _bool(json['muted']),
      hidden: _bool(json['hidden']),
      locked: _bool(json['locked']),
    );
  }
}

/// 타임라인에 그릴 트랙.
class TrackView {
  TrackView({
    required this.id,
    required this.name,
    required this.kind,
    required this.muted,
    required this.hidden,
    required this.locked,
    required this.clips,
  });

  final String id;
  final String name;
  final String kind;
  final bool muted;
  final bool hidden;
  final bool locked;
  final List<ClipView> clips;

  /// 트랙에서 가장 늦게 끝나는 클립의 타임라인 위치(ms). 클립이 없으면 0.
  int get durationMs => clips.fold<int>(
    0,
    (int maxEnd, ClipView clip) =>
        clip.endOffsetMs > maxEnd ? clip.endOffsetMs : maxEnd,
  );

  static TrackView fromJson(Map<String, dynamic> json) {
    return TrackView(
      id: _string(json['id']),
      name: _string(json['name']),
      kind: _string(json['kind'], 'video'),
      muted: _bool(json['muted']),
      hidden: _bool(json['hidden']),
      locked: _bool(json['locked']),
      clips: _mapList(json['clips']).map(ClipView.fromJson).toList(),
    );
  }
}

/// 타임라인에 그릴 클립.
class ClipView {
  ClipView({
    required this.id,
    required this.kind,
    required this.sourcePath,
    required this.startMs,
    required this.endMs,
    required this.offsetMs,
    required this.speed,
    required this.volume,
    required this.opacity,
    required this.enabled,
    required this.textContent,
    this.sourceDurationMs,
  });

  final String id;
  final String kind;
  final String sourcePath;
  final int startMs;
  final int endMs;
  final int offsetMs;
  final double speed;
  final double volume;
  final double opacity;
  final bool enabled;
  final String? textContent;

  /// 프로브로 알아낸 소스 전체 길이(없으면 트림 범위는 현재 구간 기준).
  final int? sourceDurationMs;

  /// 재생 속도를 반영한 타임라인 점유 길이(코어와 같은 계산).
  int get durationMs {
    final double safeSpeed = speed <= 0 ? 1 : speed;
    return ((endMs - startMs) / safeSpeed).round();
  }

  int get endOffsetMs => offsetMs + durationMs;

  bool contains(int atMs) => atMs >= offsetMs && atMs < endOffsetMs;

  /// 블록에 표시할 짧은 이름.
  String get label {
    final String? text = textContent;
    if (text != null && text.trim().isNotEmpty) {
      return text.trim().split('\n').first;
    }
    final List<String> parts = sourcePath.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? id : parts.last;
  }

  static ClipView fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> text = _map(json['text']);
    final String? content = text['content'] is String
        ? text['content'] as String
        : null;
    double speed = _double(json['speed'], 1);
    if (speed <= 0) {
      speed = 1;
    }
    return ClipView(
      id: _string(json['id']),
      kind: _string(json['kind'], 'video'),
      sourcePath: _string(json['source_path']),
      startMs: _int(json['start_ms']),
      endMs: _int(json['end_ms']),
      offsetMs: _int(json['timeline_offset_ms']),
      speed: speed,
      volume: _double(json['volume'], 1),
      opacity: _double(json['opacity'], 1),
      enabled: _bool(json['enabled'], true),
      textContent: content,
      sourceDurationMs: json['source_duration_ms'] is num
          ? (json['source_duration_ms'] as num).round()
          : null,
    );
  }
}

/// 자막 한 줄.
class SubtitleView {
  SubtitleView({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.autoGenerated,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String text;
  final bool autoGenerated;

  static SubtitleView fromJson(Map<String, dynamic> json) {
    return SubtitleView(
      id: _string(json['id']),
      startMs: _int(json['start_ms']),
      endMs: _int(json['end_ms']),
      text: _string(json['text']),
      autoGenerated: _bool(json['auto_generated']),
    );
  }
}

/// 내보내기 계획(Rust `ExportPlan`).
class ExportPlan {
  ExportPlan({
    required this.platform,
    required this.container,
    required this.codec,
    required this.encoderName,
    required this.encoderIsHardware,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrateKbps,
    required this.command,
    required this.notes,
  });

  final String platform;
  final String container;
  final String codec;
  final String encoderName;
  final bool encoderIsHardware;
  final int width;
  final int height;
  final int fps;
  final int bitrateKbps;
  final String command;
  final List<String> notes;

  String get summaryLabel =>
      '$container ${width}x$height@$fps · $codec · $encoderName · ${bitrateKbps}kbps · 워터마크 없음';

  static ExportPlan fromEnvelope(String text) {
    final Map<String, dynamic> envelope = _map(jsonDecode(text));
    if (envelope['ok'] == false) {
      final Map<String, dynamic> error = _map(envelope['error']);
      throw BridgeException(
        _string(error['code'], 'unknown'),
        _string(error['message'], '내보내기 계획을 만들지 못했습니다'),
      );
    }
    final Map<String, dynamic> plan = _map(envelope['plan']);
    final Map<String, dynamic> encoder = _map(plan['encoder']);
    final Map<String, dynamic> resolution = _map(plan['resolution']);
    final List<String> notes = _stringList(plan['notes']);
    return ExportPlan(
      platform: _string(plan['platform']),
      container: _string(plan['container'], 'mp4'),
      codec: _string(plan['codec'], 'h264'),
      encoderName: _string(encoder['name']),
      encoderIsHardware: _bool(encoder['hardware']),
      width: _int(resolution['width'], 1080),
      height: _int(resolution['height'], 1920),
      fps: _int(plan['fps'], 30),
      bitrateKbps: _int(plan['video_bitrate_kbps']),
      command: _string(plan['ffmpeg_command']),
      notes: notes,
    );
  }
}

List<String> _stringList(Object? value) {
  if (value is List) {
    return value.map(_string).toList(growable: false);
  }
  return const <String>[];
}

/// 플랫폼 네이티브 프로브 결과(코어가 검증한 `MediaProbeInfo`).
class MediaProbe {
  MediaProbe({
    required this.path,
    required this.durationMs,
    required this.width,
    required this.height,
    required this.fps,
    required this.hasVideo,
    required this.hasAudio,
    required this.mediaType,
    required this.clipKind,
    required this.suggestedEndMs,
    required this.summary,
    required this.warnings,
    required this.source,
  });

  final String path;
  final int durationMs;
  final int width;
  final int height;
  final double fps;
  final bool hasVideo;
  final bool hasAudio;

  /// `video` | `audio` | `image` | `unknown`
  final String mediaType;

  /// `video` | `audio` | `image` (null이면 클립을 만들 수 없다)
  final String? clipKind;
  final int? suggestedEndMs;
  final String summary;
  final List<String> warnings;
  final String source;

  bool get isImage => mediaType == 'image';

  /// 이미지/길이 없음이면 기본 5초.
  int get defaultEndMs => suggestedEndMs ?? 5000;

  static MediaProbe fromEnvelope(String text) {
    final Map<String, dynamic> envelope = _map(jsonDecode(text));
    if (envelope['ok'] == false) {
      final Map<String, dynamic> error = _map(envelope['error']);
      throw BridgeException(
        _string(error['code'], 'invalid_probe'),
        _string(error['message'], '미디어 정보를 읽지 못했습니다'),
      );
    }
    final Map<String, dynamic> probe = _map(envelope['probe']);
    final String mediaType = _string(envelope['media_type'], 'unknown');
    final Object? rawKind = envelope['clip_kind'];
    final String? clipKind = rawKind is String && rawKind.isNotEmpty
        ? rawKind
        : (mediaType == 'video' || mediaType == 'audio' || mediaType == 'image'
              ? mediaType
              : null);
    final Object? rawEnd = envelope['suggested_end_ms'];
    return MediaProbe(
      path: _string(probe['path']),
      durationMs: _int(probe['duration_ms']),
      width: _int(probe['width']),
      height: _int(probe['height']),
      fps: _double(probe['fps']),
      hasVideo: _bool(probe['has_video']),
      hasAudio: _bool(probe['has_audio']),
      mediaType: mediaType,
      clipKind: clipKind,
      suggestedEndMs: rawEnd is num ? rawEnd.round() : null,
      summary: _string(envelope['summary']),
      warnings: _stringList(envelope['warnings']),
      source: _string(probe['source'], 'unknown'),
    );
  }
}

/// 렌더 그래프 요약(코어 `RenderGraph`). 내보내기 시트와 디버깅에 쓴다.
class RenderPlanView {
  RenderPlanView({
    required this.digest,
    required this.frameCount,
    required this.durationMs,
    required this.segmentCount,
    required this.audioSegmentCount,
    required this.subtitleCount,
    required this.summary,
    required this.notes,
  });

  final String digest;
  final int frameCount;
  final int durationMs;
  final int segmentCount;
  final int audioSegmentCount;
  final int subtitleCount;
  final String summary;
  final List<String> notes;

  static RenderPlanView fromEnvelope(String text) {
    final Map<String, dynamic> envelope = _map(jsonDecode(text));
    if (envelope['ok'] == false) {
      final Map<String, dynamic> error = _map(envelope['error']);
      throw BridgeException(
        _string(error['code'], 'unknown'),
        _string(error['message'], '렌더 그래프를 만들지 못했습니다'),
      );
    }
    final Map<String, dynamic> graph = _map(envelope['graph']);
    final Map<String, dynamic> subtitles = _map(graph['subtitles']);
    final Object? rawSegments = graph['segments'];
    final Object? rawAudio = graph['audio_segments'];
    final Object? rawSubtitles = subtitles['items'];
    return RenderPlanView(
      digest: _string(graph['graph_digest']),
      frameCount: _int(graph['frame_count']),
      durationMs: _int(graph['duration_ms']),
      segmentCount: rawSegments is List ? rawSegments.length : 0,
      audioSegmentCount: rawAudio is List ? rawAudio.length : 0,
      subtitleCount: rawSubtitles is List ? rawSubtitles.length : 0,
      summary: _string(envelope['summary']),
      notes: _stringList(graph['notes']),
    );
  }
}

/// 내보내기 진행률(코어 `ExportProgress`).
class ExportProgressView {
  ExportProgressView({
    required this.state,
    required this.stateLabel,
    required this.completedFrames,
    required this.totalFrames,
    required this.fraction,
    required this.percent,
    required this.etaMs,
    required this.cancelRequested,
    required this.message,
    required this.error,
  });

  /// `queued` | `preparing` | `rendering` | `finalizing` | `completed` | `canceled` | `failed`
  final String state;
  final String stateLabel;
  final int completedFrames;
  final int totalFrames;
  final double fraction;
  final double percent;
  final int? etaMs;
  final bool cancelRequested;
  final String? message;
  final String? error;

  bool get isTerminal =>
      state == 'completed' || state == 'canceled' || state == 'failed';

  bool get isRunning => !isTerminal;

  bool get canCancel => isRunning && !cancelRequested;

  String get etaLabel {
    final int? eta = etaMs;
    if (eta == null || eta <= 0) {
      return '';
    }
    final int seconds = (eta / 1000).ceil();
    if (seconds < 60) {
      return '약 $seconds초 남음';
    }
    return '약 ${(seconds / 60).ceil()}분 남음';
  }

  /// 브리지 응답 `{ok, job:{progress:{...}}}`에서 뽑는다. 실패면 null.
  static ExportProgressView? fromEnvelope(String text) {
    final Map<String, dynamic> envelope = _map(jsonDecode(text));
    if (envelope['ok'] == false) {
      return null;
    }
    return fromJob(_map(envelope['job']));
  }

  static ExportProgressView? fromJob(Map<String, dynamic> job) {
    if (job.isEmpty) {
      return null;
    }
    final Map<String, dynamic> progress = _map(job['progress']);
    final Object? rawEta = progress['eta_ms'];
    return ExportProgressView(
      state: _string(progress['state'], 'queued'),
      stateLabel: _string(progress['state_label'], '대기 중'),
      completedFrames: _int(progress['completed_frames']),
      totalFrames: _int(progress['total_frames']),
      fraction: _double(progress['fraction']),
      percent: _double(progress['percent']),
      etaMs: rawEta is num ? rawEta.round() : null,
      cancelRequested: _bool(progress['cancel_requested']),
      message: progress['message'] is String
          ? progress['message'] as String
          : null,
      error: progress['error'] is String ? progress['error'] as String : null,
    );
  }
}

/// `ms`를 `00:00:01.500` 타임코드로.
String formatTimecode(int ms) {
  final int total = ms < 0 ? 0 : ms;
  final int hours = total ~/ 3600000;
  final int minutes = (total % 3600000) ~/ 60000;
  final int seconds = (total % 60000) ~/ 1000;
  final int millis = total % 1000;
  String pad(int value, int width) => value.toString().padLeft(width, '0');
  return '${pad(hours, 2)}:${pad(minutes, 2)}:${pad(seconds, 2)}.${pad(millis, 3)}';
}
