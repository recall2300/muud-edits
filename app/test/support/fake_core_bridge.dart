import 'dart:convert';

import 'package:muud_edits/core_bridge.dart';
import 'package:muud_edits/models.dart';

/// 테스트용 코어 브리지.
///
/// 실제 Rust 코어 없이 **Rust가 돌려주는 JSON 봉투 그대로**를 만들어 준다.
/// (위젯 테스트가 화면 흐름·상태 전이·오류 표시를 검증할 수 있게 한다.
///  실제 FFI 연결은 `test/rust_ffi_test.dart`가 검증한다.)
///
/// Rust 쪽 의미를 최소한으로 흉내 낸다:
/// * 클립/자막 id는 코어가 발급한다(`clp-0001`, `sub-0001`).
/// * 편집은 히스토리에 쌓이고 undo/redo가 대칭으로 동작한다.
/// * 겹치는 클립은 `overlap` 오류.
class FakeCoreBridge implements CoreBridge {
  FakeCoreBridge({
    this.coreVersionLabel = '0.1.0-test',
    this.failOnCreate = false,
  });

  final String coreVersionLabel;
  final bool failOnCreate;

  int _nextId = 1;

  String _name = '새 프로젝트';
  int _width = 1080;
  int _height = 1920;
  int _fps = 30;
  String? _filePath;
  bool _dirty = false;

  final List<Map<String, dynamic>> _tracks = <Map<String, dynamic>>[
    _track('video'),
    _track('audio'),
    _track('overlay'),
  ];
  final List<Map<String, dynamic>> _subtitles = <Map<String, dynamic>>[];

  /// (프로젝트 스냅샷, 되돌리기 라벨, 다시적용 라벨)
  final List<({String label, String snapshot})> _undo =
      <({String label, String snapshot})>[];
  final List<({String label, String snapshot})> _redo =
      <({String label, String snapshot})>[];

  static Map<String, dynamic> _track(String kind) => <String, dynamic>{
    'id': 'trk-${kind == 'video' ? 'video' : kind}',
    'name': switch (kind) {
      'video' => '비디오',
      'audio' => '오디오',
      _ => '오버레이',
    },
    'kind': kind,
    'muted': false,
    'hidden': false,
    'locked': false,
    'clips': <Map<String, dynamic>>[],
  };

  // ------------------------------------------------------------------ 조회용

  /// 마지막 응답(테스트에서 클립 수 등을 확인할 때).
  String? lastEnvelope;

  // -------------------------------------------------------------- CoreBridge

  @override
  Future<String> coreVersion() async => coreVersionLabel;

  @override
  Future<String> createProject({
    required String name,
    required int width,
    required int height,
    required int fps,
  }) async {
    if (failOnCreate) {
      throw BridgeException('rust_core_missing', '코어를 불러오지 못했습니다(테스트)');
    }
    _name = name;
    _width = width;
    _height = height;
    _fps = fps;
    _filePath = null;
    _dirty = false;
    _tracks
      ..clear()
      ..addAll(<Map<String, dynamic>>[
        _track('video'),
        _track('audio'),
        _track('overlay'),
      ]);
    _subtitles.clear();
    _undo.clear();
    _redo.clear();
    return _envelope();
  }

  @override
  Future<String> applyCommand(
    String stateJson,
    Map<String, dynamic> command,
  ) async {
    final String type = '${command['type']}';
    switch (type) {
      case 'remove_clip':
        _push('클립 삭제');
        _removeClip('${command['track_id']}', '${command['clip_id']}');
        return _envelope();
      case 'trim_clip':
        _push('클립 트림');
        _trimClip(
          '${command['track_id']}',
          '${command['clip_id']}',
          command,
        );
        return _envelope();
      case 'set_clip_text':
        _push('텍스트 수정');
        _setClipText(
          '${command['track_id']}',
          '${command['clip_id']}',
          (command['text'] as Map?)?['content']?.toString() ?? '',
        );
        return _envelope();
      case 'move_clip':
        _push('클립 이동');
        _moveClip('${command['track_id']}', command);
        return _envelope();
      case 'set_track_state':
        _push('트랙 상태');
        _setTrackState('${command['track_id']}', command);
        return _envelope();
      case 'update_subtitle':
        _push('자막 수정');
        _updateSubtitle(
          '${command['id']}',
          (command['patch'] as Map?) ?? const <String, dynamic>{},
        );
        return _envelope();
      case 'remove_subtitle':
        _push('자막 삭제');
        _subtitles.removeWhere(
          (Map<String, dynamic> item) => item['id'] == '${command['id']}',
        );
        return _envelope();
      case 'add_clip':
        _push('클립 추가');
        final Map<String, dynamic> clip = (command['clip'] as Map)
            .cast<String, dynamic>();
        _addClip('${command['track_id']}', clip);
        return _envelope(createdId: '${clip['id']}');
      default:
        throw BridgeException('bad_command', '지원하지 않는 커맨드: $type');
    }
  }

  @override
  Future<String> addMediaClip({
    required String stateJson,
    required String trackId,
    required String kind,
    required String sourcePath,
    required int startMs,
    required int endMs,
    int? atMs,
    int? sourceDurationMs,
  }) async {
    _push('미디어 추가');
    final String id = _mint('clp');
    final int duration = sourceDurationMs ?? (endMs - startMs);
    final Map<String, dynamic> track = _trackById(trackId);
    final int offset = atMs ?? _trackEnd(track);
    _addClip(trackId, <String, dynamic>{
      'id': id,
      'kind': kind,
      'source_path': sourcePath,
      'start_ms': startMs,
      'end_ms': startMs + duration,
      'timeline_offset_ms': offset,
      'speed': 1,
      'volume': 1,
      'opacity': 1,
      'enabled': true,
      if (sourceDurationMs != null) 'source_duration_ms': sourceDurationMs,
    });
    return _envelope(createdId: id);
  }

  @override
  Future<String> addTextClip({
    required String stateJson,
    required String trackId,
    required String content,
    required int durationMs,
    required int atMs,
  }) async {
    _push('텍스트 추가');
    final String id = _mint('clp');
    _addClip(trackId, <String, dynamic>{
      'id': id,
      'kind': 'text',
      'source_path': '',
      'start_ms': 0,
      'end_ms': durationMs,
      'timeline_offset_ms': atMs,
      'speed': 1,
      'volume': 1,
      'opacity': 1,
      'enabled': true,
      'text': <String, dynamic>{'content': content},
    });
    return _envelope(createdId: id);
  }

  @override
  Future<String> addSubtitle({
    required String stateJson,
    required String text,
    int? startMs,
    int? endMs,
  }) async {
    _push('자막 추가');
    final String id = _mint('sub');
    final int start = startMs ?? _lastSubtitleEnd();
    _subtitles.add(<String, dynamic>{
      'id': id,
      'start_ms': start,
      'end_ms': endMs ?? start + 2000,
      'text': text,
      'auto_generated': false,
    });
    return _envelope(createdId: id);
  }

  @override
  Future<String> splitClip({
    required String stateJson,
    required String trackId,
    required String clipId,
    required int atTimelineMs,
  }) async {
    _push('클립 분할');
    final Map<String, dynamic> track = _trackById(trackId);
    final List<Map<String, dynamic>> clips = (track['clips'] as List)
        .cast<Map<String, dynamic>>();
    final int index = clips.indexWhere(
      (Map<String, dynamic> clip) => clip['id'] == clipId,
    );
    if (index < 0) {
      throw BridgeException('not_found', '클립을 찾지 못했습니다');
    }
    final Map<String, dynamic> left = clips[index];
    final int cut =
        atTimelineMs -
        (left['timeline_offset_ms'] as int) +
        (left['start_ms'] as int);
    final String rightId = _mint('clp');
    final Map<String, dynamic> right = <String, dynamic>{
      ...left,
      'id': rightId,
      'start_ms': cut,
      'timeline_offset_ms': atTimelineMs,
    };
    left['end_ms'] = cut;
    clips.insert(index + 1, right);
    return _envelope(createdId: rightId);
  }

  @override
  Future<String> undo(String stateJson) async {
    if (_undo.isEmpty) {
      throw BridgeException('empty_history', '되돌릴 편집이 없습니다');
    }
    final ({String label, String snapshot}) last = _undo.removeLast();
    _redo.add((label: last.label, snapshot: _snapshot()));
    _restore(last.snapshot);
    return _envelope(action: 'undo', outcomeLabel: last.label);
  }

  @override
  Future<String> redo(String stateJson) async {
    if (_redo.isEmpty) {
      throw BridgeException('empty_history', '다시 적용할 편집이 없습니다');
    }
    final ({String label, String snapshot}) last = _redo.removeLast();
    _undo.add((label: last.label, snapshot: _snapshot()));
    _restore(last.snapshot);
    return _envelope(action: 'redo', outcomeLabel: last.label);
  }

  @override
  Future<String> exportPlan({
    required String stateJson,
    required String settingsJson,
    required String platformId,
  }) async {
    return jsonEncode(<String, dynamic>{
      'ok': true,
      'plan': <String, dynamic>{
        'platform': platformId,
        'container': 'mp4',
        'codec': 'h264',
        'encoder': <String, dynamic>{'name': 'fake_encoder', 'hardware': false},
        'width': _width,
        'height': _height,
        'fps': _fps,
        'bitrate_kbps': 8000,
        'command': 'ffmpeg -i <input> -c:v fake_encoder <output>.mp4',
        'notes': <String>['테스트 계획'],
        'watermark': false,
        'output_extension': 'mp4',
      },
      'summary': _summary(),
    });
  }

  @override
  Future<String> renderGraph({
    required String stateJson,
    required String settingsJson,
    required String platformId,
  }) async {
    final int frames = (_durationMs() / (1000 / _fps)).round();
    return jsonEncode(<String, dynamic>{
      'ok': true,
      'graph': <String, dynamic>{
        'frame_count': frames,
        'segments': <Map<String, dynamic>>[],
        'audio_segments': <Map<String, dynamic>>[],
        'subtitles': <Map<String, dynamic>>[],
        'encoder': <String, dynamic>{'name': 'fake_encoder'},
        'graph_digest': '0123456789abcdef',
        'range': <String, dynamic>{'start_ms': 0, 'end_ms': _durationMs()},
      },
      'summary': '${frames} frames · 그래프',
    });
  }

  @override
  Future<String> probeMediaInfo(String probeJson) async {
    final Map<String, dynamic> probe = (jsonDecode(probeJson) as Map)
        .cast<String, dynamic>();
    final bool hasVideo = probe['has_video'] == true;
    return jsonEncode(<String, dynamic>{
      'ok': true,
      'probe': probe,
      'media_type': hasVideo ? 'video' : 'audio',
      'clip_kind': hasVideo ? 'video' : 'audio',
      'suggested_end_ms': probe['duration_ms'] ?? 0,
      'summary':
          '${probe['width'] ?? 0}x${probe['height'] ?? 0} · '
          '${probe['duration_ms'] ?? 0}ms',
      'warnings': <String>[],
    });
  }

  @override
  Future<String> exportJobCreate({
    required String jobId,
    required int totalFrames,
    int? atMs,
  }) async {
    return jsonEncode(<String, dynamic>{
      'ok': true,
      'job': <String, dynamic>{
        'id': jobId,
        'total_frames': totalFrames,
        'progress': <String, dynamic>{
          'state': 'queued',
          'completed_frames': 0,
          'percent': 0.0,
          'cancel_requested': false,
        },
      },
      'summary': 'queued',
    });
  }

  @override
  Future<String> exportJobEvent({
    required String jobJson,
    required String eventJson,
  }) async {
    final Map<String, dynamic> job = (jsonDecode(jobJson) as Map)
        .cast<String, dynamic>();
    final Map<String, dynamic> event = (jsonDecode(eventJson) as Map)
        .cast<String, dynamic>();
    final Map<String, dynamic> progress =
        ((job['progress'] as Map?) ?? <String, dynamic>{})
            .cast<String, dynamic>();
    final String type = '${event['type']}';
    if (type == 'progress') {
      final int completed = (event['completed_frames'] as num?)?.toInt() ?? 0;
      final int total = (job['total_frames'] as num?)?.toInt() ?? 0;
      progress['state'] = 'rendering';
      progress['completed_frames'] = completed;
      progress['percent'] = total == 0 ? 0.0 : (completed * 100 / total);
    } else if (type == 'completed') {
      progress['state'] = 'completed';
      progress['percent'] = 100.0;
    } else if (type == 'cancel_request') {
      progress['cancel_requested'] = true;
    } else if (type == 'canceled') {
      progress['state'] = 'canceled';
    } else if (type == 'failed') {
      progress['state'] = 'failed';
      progress['error'] = '${event['message'] ?? '실패'}';
    }
    job['progress'] = progress;
    return jsonEncode(<String, dynamic>{
      'ok': true,
      'applied': true,
      'job': job,
      'summary': progress['state'],
    });
  }

  @override
  Future<String> exportJobCancel({required String jobJson, int? atMs}) {
    return exportJobEvent(
      jobJson: jobJson,
      eventJson: jsonEncode(<String, dynamic>{'type': 'cancel_request'}),
    );
  }

  @override
  Future<String> saveProject({
    required String stateJson,
    required String path,
  }) async {
    _filePath = path;
    _dirty = false;
    return _envelope();
  }

  @override
  Future<String> loadProject(String path) async {
    _filePath = path;
    return _envelope();
  }

  @override
  Future<String> saveSubtitlesSrt({
    required String stateJson,
    required String path,
  }) async {
    return jsonEncode(<String, dynamic>{
      'ok': true,
      'written': _subtitles.isEmpty ? null : path,
    });
  }

  // ------------------------------------------------------------- 내부 모델

  String _mint(String prefix) =>
      '$prefix-${(_nextId++).toString().padLeft(4, '0')}';

  Map<String, dynamic> _trackById(String id) {
    for (final Map<String, dynamic> track in _tracks) {
      if (track['id'] == id) {
        return track;
      }
    }
    throw BridgeException('not_found', '트랙을 찾지 못했습니다: $id');
  }

  int _trackEnd(Map<String, dynamic> track) {
    int end = 0;
    for (final Map<String, dynamic> clip
        in (track['clips'] as List).cast<Map<String, dynamic>>()) {
      final int clipEnd =
          (clip['timeline_offset_ms'] as int) +
          ((clip['end_ms'] as int) - (clip['start_ms'] as int));
      if (clipEnd > end) {
        end = clipEnd;
      }
    }
    return end;
  }

  void _addClip(String trackId, Map<String, dynamic> clip) {
    final Map<String, dynamic> track = _trackById(trackId);
    final List<Map<String, dynamic>> clips = (track['clips'] as List)
        .cast<Map<String, dynamic>>();
    final int start = clip['timeline_offset_ms'] as int? ?? 0;
    final int end =
        start + ((clip['end_ms'] as int) - (clip['start_ms'] as int));
    for (final Map<String, dynamic> other in clips) {
      final int otherStart = other['timeline_offset_ms'] as int;
      final int otherEnd =
          otherStart + ((other['end_ms'] as int) - (other['start_ms'] as int));
      if (start < otherEnd && otherStart < end) {
        throw BridgeException('overlap', '클립이 겹칩니다');
      }
    }
    clips.add(clip);
  }

  void _setClipText(String trackId, String clipId, String content) {
    final Map<String, dynamic> track = _trackById(trackId);
    for (final dynamic raw in (track['clips'] as List)) {
      final Map<String, dynamic> clip = (raw as Map).cast<String, dynamic>();
      if (clip['id'] == clipId) {
        clip['text'] = <String, dynamic>{'content': content};
        return;
      }
    }
  }

  void _updateSubtitle(String id, Map<dynamic, dynamic> patch) {
    for (final Map<String, dynamic> item in _subtitles) {
      if (item['id'] != id) {
        continue;
      }
      if (patch['text'] != null) {
        item['text'] = '${patch['text']}';
      }
      if (patch['start_ms'] != null) {
        item['start_ms'] = (patch['start_ms'] as num).toInt();
      }
      if (patch['end_ms'] != null) {
        item['end_ms'] = (patch['end_ms'] as num).toInt();
      }
      return;
    }
  }

  void _trimClip(String trackId, String clipId, Map<dynamic, dynamic> command) {    final Map<String, dynamic> track = _trackById(trackId);
    for (final dynamic raw in (track['clips'] as List)) {
      final Map<String, dynamic> clip = (raw as Map).cast<String, dynamic>();
      if (clip['id'] != clipId) {
        continue;
      }
      if (command['start_ms'] != null) {
        clip['start_ms'] = (command['start_ms'] as num).toInt();
      }
      if (command['end_ms'] != null) {
        clip['end_ms'] = (command['end_ms'] as num).toInt();
      }
      if (command['timeline_offset_ms'] != null) {
        clip['timeline_offset_ms'] = (command['timeline_offset_ms'] as num).toInt();
      }
      return;
    }
  }

  /// 클립 이동(타임라인 위치 변경). 코어의 `move_clip` 최소 동작.
  void _moveClip(String trackId, Map<dynamic, dynamic> command) {
    final String clipId = '${command['clip_id']}';
    final String targetTrackId =
        '${command['to_track_id'] ?? command['track_id']}';
    final int offset = (command['timeline_offset_ms'] as num?)?.toInt() ?? 0;
    final Map<String, dynamic> track = _trackById(trackId);
    final List<dynamic> clips = track['clips'] as List;
    int index = -1;
    for (int i = 0; i < clips.length; i++) {
      if ((clips[i] as Map)['id'] == clipId) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      throw BridgeException('not_found', '클립을 찾지 못했습니다: $clipId');
    }
    final Map<String, dynamic> moving =
        (clips.removeAt(index) as Map).cast<String, dynamic>();
    moving['timeline_offset_ms'] = offset;
    _addClip(targetTrackId, moving);
  }

  /// 트랙 상태(음소거/숨김/잠금).
  void _setTrackState(String trackId, Map<dynamic, dynamic> command) {
    final Map<String, dynamic> track = _trackById(trackId);
    for (final String key in <String>['muted', 'hidden', 'locked']) {
      if (command[key] != null) {
        track[key] = command[key] == true;
      }
    }
  }

  void _removeClip(String trackId, String clipId) {
    final Map<String, dynamic> track = _trackById(trackId);
    (track['clips'] as List).removeWhere(
      (dynamic clip) => (clip as Map)['id'] == clipId,
    );
  }

  int _lastSubtitleEnd() {
    int end = 0;
    for (final Map<String, dynamic> subtitle in _subtitles) {
      final int value = subtitle['end_ms'] as int;
      if (value > end) {
        end = value;
      }
    }
    return end;
  }

  int _durationMs() {
    int end = 0;
    for (final Map<String, dynamic> track in _tracks) {
      final int trackEnd = _trackEnd(track);
      if (trackEnd > end) {
        end = trackEnd;
      }
    }
    for (final Map<String, dynamic> subtitle in _subtitles) {
      final int value = subtitle['end_ms'] as int;
      if (value > end) {
        end = value;
      }
    }
    return end;
  }

  int get _clipCount => _tracks.fold<int>(
    0,
    (int sum, Map<String, dynamic> track) =>
        sum + (track['clips'] as List).length,
  );

  String _snapshot() => jsonEncode(<String, dynamic>{
    'tracks': _tracks,
    'subtitles': _subtitles,
    'name': _name,
    'file_path': _filePath,
    'dirty': _dirty,
  });

  void _restore(String snapshot) {
    final Map<String, dynamic> data = (jsonDecode(snapshot) as Map)
        .cast<String, dynamic>();
    _tracks
      ..clear()
      ..addAll(
        (data['tracks'] as List).map(
          (dynamic track) => (track as Map).cast<String, dynamic>(),
        ),
      );
    _subtitles
      ..clear()
      ..addAll(
        (data['subtitles'] as List).map(
          (dynamic item) => (item as Map).cast<String, dynamic>(),
        ),
      );
    _name = '${data['name']}';
    _filePath = data['file_path'] as String?;
    _dirty = data['dirty'] as bool? ?? false;
  }

  void _push(String label) {
    _undo.add((label: label, snapshot: _snapshot()));
    _redo.clear();
    _dirty = true;
  }

  Map<String, dynamic> _summary() {
    final int duration = _durationMs();
    return <String, dynamic>{
      'id': 'prj-test',
      'name': _name,
      'resolution': <String, dynamic>{'width': _width, 'height': _height},
      'fps': _fps,
      'duration_ms': duration,
      'duration_label': formatTimecode(duration),
      'track_count': _tracks.length,
      'clip_count': _clipCount,
      'subtitle_count': _subtitles.length,
      'can_undo': _undo.isNotEmpty,
      'can_redo': _redo.isNotEmpty,
      'dirty': _dirty,
      'file_path': _filePath,
      'undo_label': _undo.isEmpty ? null : _undo.last.label,
      'redo_label': _redo.isEmpty ? null : _redo.last.label,
      'undo_depth': _undo.length,
      'redo_depth': _redo.length,
      'tracks': <Map<String, dynamic>>[
        for (final Map<String, dynamic> track in _tracks)
          <String, dynamic>{
            'id': track['id'],
            'name': track['name'],
            'kind': track['kind'],
            'clip_count': (track['clips'] as List).length,
            'duration_ms': _trackEnd(track),
            'muted': track['muted'],
            'hidden': track['hidden'],
            'locked': track['locked'],
          },
      ],
    };
  }

  Map<String, dynamic> _state() => <String, dynamic>{
    'project': <String, dynamic>{
      'id': 'prj-test',
      'name': _name,
      'resolution': <String, dynamic>{'width': _width, 'height': _height},
      'fps': _fps,
      'tracks': _tracks,
      'subtitles': <String, dynamic>{'items': _subtitles},
      'export': <String, dynamic>{},
      'file_path': _filePath,
    },
    'history': <String, dynamic>{
      'undo_depth': _undo.length,
      'redo_depth': _redo.length,
    },
  };

  String _envelope({String? createdId, String? action, String? outcomeLabel}) {
    final Map<String, dynamic> envelope = <String, dynamic>{
      'ok': true,
      'state': _state(),
      'summary': _summary(),
    };
    if (createdId != null) {
      envelope['created_id'] = createdId;
    }
    if (action != null) {
      envelope['outcome'] = <String, dynamic>{
        'action': action,
        'label': outcomeLabel,
      };
    }
    lastEnvelope = jsonEncode(envelope);
    return lastEnvelope!;
  }
}
