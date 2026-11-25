import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, Platform;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'commands.dart';
import 'core_bridge.dart';
import 'media/media_platform_bridge.dart';
import 'models.dart';

/// 편집 화면의 상태 관리자.
///
/// 원칙:
/// * **상태는 불변**이다. 모든 변경은 Rust 코어에 커맨드로 보내고, 돌아온 새 상태로 교체한다.
/// * UI는 여기 있는 메서드만 호출한다(브리지를 직접 부르지 않는다).
/// * 오류는 던지지 않고 [error]에 담는다 → 화면이 배너/스낵바로 보여준다.
class EditorController extends ChangeNotifier {
  EditorController({CoreBridge? bridge, MediaPlatformBridge? media})
    : _bridge = bridge ?? const FrbCoreBridge(),
      _media = media ?? MethodChannelMediaBridge();

  final CoreBridge _bridge;
  final MediaPlatformBridge _media;

  EditorState? _state;
  bool _busy = false;
  bool _bridgeReady = false;
  String _coreVersion = '';
  String? _error;
  String? _notice;
  String? _selectedClipId;
  int _playheadMs = 0;
  ExportPlan? _lastPlan;
  RenderPlanView? _lastRenderPlan;
  String _exportPlatform = 'android';
  StreamSubscription<MediaExportEvent>? _progressSub;
  String? _exportJobJson;
  ExportProgressView? _exportProgress;
  String? _exportOutputPath;
  bool _mediaEngineMissing = false;
  String? _lastProbeSummary;

  // ------------------------------------------------------------------ getters

  EditorState? get state => _state;

  bool get ready => _state != null;

  bool get busy => _busy;

  bool get bridgeReady => _bridgeReady;

  String get coreVersion => _coreVersion;

  String? get error => _error;

  String? get notice => _notice;

  String? get selectedClipId => _selectedClipId;

  int get playheadMs => _playheadMs;

  ExportPlan? get lastPlan => _lastPlan;

  RenderPlanView? get lastRenderPlan => _lastRenderPlan;

  ExportProgressView? get exportProgress => _exportProgress;

  String? get exportOutputPath => _exportOutputPath;

  bool get mediaEngineMissing => _mediaEngineMissing;

  String? get lastProbeSummary => _lastProbeSummary;

  /// 지금 앱이 도는 플랫폼. 네이티브 엔진은 이 플랫폼용 그래프만 렌더할 수 있다.
  String get currentPlatformId {
    if (Platform.isMacOS) {
      return 'macos';
    }
    if (Platform.isWindows) {
      return 'windows';
    }
    if (Platform.isAndroid) {
      return 'android';
    }
    if (Platform.isIOS) {
      return 'ios';
    }
    return 'linux';
  }

  String get exportPlatform => _exportPlatform;

  int get durationMs => _state?.durationMs ?? 0;

  int get frameMs {
    final int fps = _state?.fps ?? 30;
    return (1000 / (fps <= 0 ? 30 : fps)).round();
  }

  /// Rust로 그대로 돌려보내는 상태 JSON.
  String get stateJson {
    final EditorState? current = _state;
    if (current == null) {
      return '{}';
    }
    return jsonEncode(current.raw);
  }

  /// 선택된 클립과 그 트랙.
  ({TrackView track, ClipView clip})? get selected {
    final String? id = _selectedClipId;
    if (id == null) {
      return null;
    }
    return _state?.findClip(id);
  }

  /// 재생 헤드 위에서 가장 위에 보이는 클립.
  ({TrackView track, ClipView clip})? clipAtPlayhead() {
    final EditorState? current = _state;
    if (current == null) {
      return null;
    }
    for (final TrackView track in current.tracks.reversed) {
      if (track.hidden) {
        continue;
      }
      for (final ClipView clip in track.clips) {
        if (clip.enabled && clip.contains(_playheadMs)) {
          return (track: track, clip: clip);
        }
      }
    }
    return null;
  }

  TrackView? get firstOverlayTrack {
    final EditorState? current = _state;
    if (current == null) {
      return null;
    }
    for (final TrackView track in current.tracks) {
      if (track.kind == 'overlay') {
        return track;
      }
    }
    return null;
  }

  // ------------------------------------------------------------------ actions

  /// 코어를 깨우고 새 프로젝트를 만든다.
  Future<void> bootstrap() async {
    _busy = true;
    _error = null;
    _exportPlatform = currentPlatformId;
    _progressSub ??= _media.progressStream.listen(
      (MediaExportEvent event) => unawaited(_onMediaExportEvent(event)),
      onError: (Object error) {
        _error = '내보내기 이벤트 오류: $error';
        notifyListeners();
      },
    );
    notifyListeners();
    try {
      _coreVersion = await _bridge.coreVersion();
      _bridgeReady = true;
      final String raw = await _bridge.createProject(
        name: '새 프로젝트',
        width: 1080,
        height: 1920,
        fps: 30,
      );
      _state = EditorState.fromEnvelope(raw);
      _playheadMs = 0;
      _selectedClipId = null;
      _notice = '코어 ${_coreVersion.isEmpty ? '' : 'v$_coreVersion '}연결됨';
    } on BridgeException catch (error) {
      _bridgeReady = false;
      _error = error.message;
    } catch (error) {
      _bridgeReady = false;
      _error =
          'Rust 코어를 불러오지 못했습니다.\n'
          '`dart run flutter_rust_bridge_codegen generate` 후 다시 실행하세요.\n\n$error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 새 프로젝트를 만든다(지금 편집 중인 내용은 버린다).
  ///
  /// 코어가 아직 준비되지 않았으면 [bootstrap]을 다시 시도한다.
  Future<void> newProject({String? name}) async {
    if (!_bridgeReady) {
      await bootstrap();
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final String label = (name == null || name.trim().isEmpty)
          ? '새 프로젝트'
          : name.trim();
      final String raw = await _bridge.createProject(
        name: label,
        width: 1080,
        height: 1920,
        fps: 30,
      );
      _state = EditorState.fromEnvelope(raw);
      _playheadMs = 0;
      _selectedClipId = null;
      _lastPlan = null;
      _lastRenderPlan = null;
      _exportProgress = null;
      _exportOutputPath = null;
      _exportJobJson = null;
      _notice = '새 프로젝트를 만들었습니다';
    } on BridgeException catch (error) {
      _error = error.message;
    } catch (error) {
      _error = '새 프로젝트를 만들지 못했습니다: $error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 임의 커맨드 적용.
  Future<void> apply(Map<String, dynamic> command) {
    return _mutate(() => _bridge.applyCommand(stateJson, command));
  }

  Future<void> undo() => _mutate(() => _bridge.undo(stateJson));

  Future<void> redo() => _mutate(() => _bridge.redo(stateJson));

  /// 재생 헤드에서 클립 분할.
  Future<void> splitAtPlayhead() async {
    final ({TrackView track, ClipView clip})? hit = clipAtPlayhead();
    if (hit == null) {
      _notice = '재생 헤드 위에 클립이 없습니다';
      notifyListeners();
      return;
    }
    final int at = _playheadMs;
    await _mutate(
      () => _bridge.splitClip(
        stateJson: stateJson,
        trackId: hit.track.id,
        clipId: hit.clip.id,
        atTimelineMs: at,
      ),
    );
  }

  /// 선택 클립 삭제.
  Future<void> deleteSelected() async {
    final ({TrackView track, ClipView clip})? hit = selected;
    if (hit == null) {
      return;
    }
    await apply(
      Commands.removeClip(trackId: hit.track.id, clipId: hit.clip.id),
    );
    _selectedClipId = null;
  }

  /// 선택 클립 앞/뒤를 프레임 단위로 다듬는다(음수 = 줄이기).
  Future<void> nudgeTrim({required bool fromStart, required int frames}) async {
    final ({TrackView track, ClipView clip})? hit = selected;
    if (hit == null) {
      return;
    }
    final int delta = frames * frameMs;
    if (fromStart) {
      final int nextStart = hit.clip.startMs + delta;
      await apply(
        Commands.trimClip(
          trackId: hit.track.id,
          clipId: hit.clip.id,
          startMs: nextStart < 0 ? 0 : nextStart,
        ),
      );
    } else {
      final int nextEnd = hit.clip.endMs + delta;
      await apply(
        Commands.trimClip(
          trackId: hit.track.id,
          clipId: hit.clip.id,
          endMs: nextEnd <= hit.clip.startMs
              ? hit.clip.startMs + frameMs
              : nextEnd,
        ),
      );
    }
  }

  Future<void> setSpeed(double speed) async {
    final ({TrackView track, ClipView clip})? hit = selected;
    if (hit == null) {
      return;
    }
    await apply(
      Commands.setSpeed(
        trackId: hit.track.id,
        clipId: hit.clip.id,
        speed: speed.clamp(0.25, 4.0).toDouble(),
      ),
    );
  }

  Future<void> setVolume(double volume) async {
    final ({TrackView track, ClipView clip})? hit = selected;
    if (hit == null) {
      return;
    }
    await apply(
      Commands.setVolume(
        trackId: hit.track.id,
        clipId: hit.clip.id,
        volume: volume.clamp(0.0, 2.0).toDouble(),
      ),
    );
  }

  Future<void> setOpacity(double opacity) async {
    final ({TrackView track, ClipView clip})? hit = selected;
    if (hit == null) {
      return;
    }
    await apply(
      Commands.setOpacity(
        trackId: hit.track.id,
        clipId: hit.clip.id,
        opacity: opacity.clamp(0.0, 1.0).toDouble(),
      ),
    );
  }

  /// 클립을 재생 헤드 위치로 이동(같은 트랙).
  Future<void> moveSelectedToPlayhead() async {
    final ({TrackView track, ClipView clip})? hit = selected;
    if (hit == null) {
      return;
    }
    await apply(
      Commands.moveClip(
        trackId: hit.track.id,
        clipId: hit.clip.id,
        atMs: _playheadMs,
      ),
    );
  }

  /// 미디어 클립 추가(프로브가 붙기 전까지는 길이를 사용자가 지정한다).
  Future<void> addMediaClip({
    required String sourcePath,
    required String kind,
    required int startMs,
    required int endMs,
    int? atMs,
    int? sourceDurationMs,
  }) {
    return _mutate(
      () => _bridge.addMediaClip(
        stateJson: stateJson,
        trackId: _trackIdForKind(kind),
        kind: kind,
        sourcePath: sourcePath,
        startMs: startMs,
        endMs: endMs,
        atMs: atMs,
        sourceDurationMs: sourceDurationMs,
      ),
    );
  }

  /// 파일 경로를 받아 **네이티브 프로브 → 코어 검증 → 클립 추가**까지 처리한다.
  ///
  /// 네이티브 엔진이 없으면(스캐폴딩만 있는 상태) 경고를 남기고 기본 5초로 넣는다.
  Future<void> addMediaFile(String sourcePath) async {
    final MediaProbe? probe = await probeFile(sourcePath);
    final String kind = probe?.clipKind ?? _kindFromExtension(sourcePath);
    final int endMs = probe == null
        ? 5000
        : (probe.isImage ? 5000 : probe.defaultEndMs);
    _lastProbeSummary = probe == null
        ? '프로브 없이 추가: 기본 ${(endMs / 1000).round()}초'
        : <String>[probe.summary, ...probe.warnings].join(' · ');
    if (probe != null) {
      _notice = '미디어 추가: $_lastProbeSummary';
      notifyListeners();
    }
    await addMediaClip(
      sourcePath: sourcePath,
      kind: kind,
      startMs: 0,
      endMs: endMs,
      sourceDurationMs: probe?.suggestedEndMs,
    );
  }

  /// 네이티브 프로브 → 코어 검증. 실패하면 null(오류는 [error]/[notice]).
  Future<MediaProbe?> probeFile(String path) async {
    try {
      final Map<String, dynamic> raw = await _media.probe(path);
      final String normalized = await _bridge.probeMediaInfo(jsonEncode(raw));
      final MediaProbe probe = MediaProbe.fromEnvelope(normalized);
      _mediaEngineMissing = false;
      return probe;
    } on MediaPlatformException catch (error) {
      _mediaEngineMissing = error.isEngineMissing;
      _notice = error.isEngineMissing
          ? '네이티브 미디어 엔진이 연결되지 않아 길이를 직접 정합니다'
          : error.message;
      notifyListeners();
      return null;
    } on BridgeException catch (error) {
      _error = error.message;
      notifyListeners();
      return null;
    } catch (error) {
      _error = '미디어 정보를 읽지 못했습니다: $error';
      notifyListeners();
      return null;
    }
  }

  String _kindFromExtension(String path) {
    final String ext = path.toLowerCase().split('.').last;
    const Set<String> audio = <String>{
      'm4a',
      'mp3',
      'wav',
      'aac',
      'flac',
      'opus',
      'ogg',
    };
    const Set<String> image = <String>{
      'jpg',
      'jpeg',
      'png',
      'heic',
      'heif',
      'webp',
      'gif',
    };
    if (audio.contains(ext)) {
      return 'audio';
    }
    if (image.contains(ext)) {
      return 'image';
    }
    return 'video';
  }

  /// 텍스트 오버레이 추가(재생 헤드 위치).
  Future<void> addTextOverlay(String content, {int durationMs = 2500}) async {
    final TrackView? track = firstOverlayTrack;
    if (track == null) {
      _notice = '오버레이 트랙이 없습니다';
      notifyListeners();
      return;
    }
    final int at = _playheadMs;
    await _mutate(
      () => _bridge.addTextClip(
        stateJson: stateJson,
        trackId: track.id,
        content: content,
        durationMs: durationMs,
        atMs: at,
      ),
    );
  }

  /// 자막 추가(재생 헤드에서 2초).
  Future<void> addSubtitleHere(String text) async {
    final int start = _playheadMs;
    await _mutate(
      () => _bridge.addSubtitle(
        stateJson: stateJson,
        text: text,
        startMs: start,
        endMs: start + 2000,
      ),
    );
  }

  /// 내보내기 계획 준비(검증 + 인코더 선택 + 렌더 그래프).
  Future<void> prepareExport() async {
    if (_state == null) {
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final String raw = await _bridge.exportPlan(
        stateJson: stateJson,
        settingsJson: '',
        platformId: _exportPlatform,
      );
      _lastPlan = ExportPlan.fromEnvelope(raw);
      final String graphRaw = await _bridge.renderGraph(
        stateJson: stateJson,
        settingsJson: '',
        platformId: _exportPlatform,
      );
      _lastRenderPlan = RenderPlanView.fromEnvelope(graphRaw);
    } on BridgeException catch (error) {
      _lastPlan = null;
      _lastRenderPlan = null;
      _error = error.message;
    } catch (error) {
      _lastPlan = null;
      _lastRenderPlan = null;
      _error = '$error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 렌더 그래프를 만들어 **네이티브 엔진에 넘긴다**. 진행률은 이벤트로 돌아온다.
  ///
  /// 계획 칼럼은 `_exportPlatform`(미리보기)이고, 실제 렌더는 언제나
  /// `currentPlatformId`(이 기기의 네이티브 엔진)로 한다.
  Future<void> startExport({String? outputPath}) async {
    if (_state == null || (_exportProgress?.isRunning ?? false)) {
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final String platformId = currentPlatformId;
      final String graphRaw = await _bridge.renderGraph(
        stateJson: stateJson,
        settingsJson: '',
        platformId: platformId,
      );
      _lastRenderPlan = RenderPlanView.fromEnvelope(graphRaw);
      final Map<String, dynamic> graphEnvelope = _decodeEnvelope(graphRaw);
      final Map<String, dynamic> graph = _mapOf(graphEnvelope['graph']);
      if (graph.isEmpty) {
        throw BridgeException('bad_graph', '렌더 그래프가 비어 있습니다');
      }

      final String path = outputPath ?? await _defaultExportPath();
      _exportOutputPath = path;

      final String jobRaw = await _bridge.exportJobCreate(
        jobId: 'job-${DateTime.now().millisecondsSinceEpoch}',
        totalFrames: _lastRenderPlan?.frameCount ?? 0,
      );
      final Map<String, dynamic> jobEnvelope = _decodeEnvelope(jobRaw);
      _exportJobJson = jsonEncode(jobEnvelope['job']);
      _exportProgress = ExportProgressView.fromJob(_mapOf(jobEnvelope['job']));

      await _media.startExport(graphJson: jsonEncode(graph), outputPath: path);
      _notice = '내보내기를 시작했습니다 · $path';
    } on MediaPlatformException catch (error) {
      _mediaEngineMissing = error.isEngineMissing;
      _exportProgress = null;
      _error = error.isEngineMissing
          ? '이 플랫폼의 네이티브 미디어 엔진이 연결되지 않았습니다.\n'
                'docs/LOCAL_SETUP.md의 "네이티브 미디어 레이어 연결"을 따라 주세요.'
          : error.message;
    } on BridgeException catch (error) {
      _error = error.message;
    } catch (error) {
      _error = '내보내기를 시작하지 못했습니다: $error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 사용자 취소. 코어 상태에 요청을 남기고 네이티브에 전달한다.
  Future<void> cancelExport() async {
    final String? jobJson = _exportJobJson;
    if (jobJson == null) {
      return;
    }
    try {
      final String raw = await _bridge.exportJobCancel(jobJson: jobJson);
      final Map<String, dynamic> envelope = _decodeEnvelope(raw);
      _exportProgress =
          ExportProgressView.fromJob(_mapOf(envelope['job'])) ??
          _exportProgress;
      _exportJobJson = jsonEncode(envelope['job']);
      final bool accepted = await _media.cancelExport();
      if (!accepted) {
        _notice = '취소 요청을 보냈지만 엔진이 아직 응답하지 않았습니다';
      }
    } on MediaPlatformException catch (error) {
      _error = error.message;
    } on BridgeException catch (error) {
      _error = error.message;
    } catch (error) {
      _error = '취소하지 못했습니다: $error';
    }
    notifyListeners();
  }

  /// 네이티브 이벤트 → 코어 상태 기계 → UI 스낵바/진행률.
  Future<void> _onMediaExportEvent(MediaExportEvent event) async {
    final String? jobJson = _exportJobJson;
    if (jobJson == null) {
      return;
    }
    final Map<String, dynamic> map;
    if (event.event == 'completed') {
      map = <String, dynamic>{'type': 'completed'};
    } else if (event.event == 'failed') {
      map = <String, dynamic>{
        'type': 'failed',
        'message': event.error ?? event.message ?? '내보내기에 실패했습니다',
      };
    } else if (event.event == 'canceled') {
      map = <String, dynamic>{'type': 'canceled'};
    } else if (event.event == 'stage') {
      map = <String, dynamic>{
        'type': 'stage',
        'state': event.state ?? 'rendering',
      };
    } else {
      map = <String, dynamic>{
        'type': 'progress',
        'completed_frames': event.completedFrames ?? 0,
      };
    }
    try {
      final String raw = await _bridge.exportJobEvent(
        jobJson: jobJson,
        eventJson: jsonEncode(map),
      );
      final Map<String, dynamic> envelope = _decodeEnvelope(raw);
      _exportJobJson = jsonEncode(envelope['job']);
      final ExportProgressView? next = ExportProgressView.fromJob(
        _mapOf(envelope['job']),
      );
      if (next != null) {
        _exportProgress = next;
        if (next.state == 'completed') {
          _notice = '내보내기 완료 · ${_exportOutputPath ?? ''}';
        } else if (next.state == 'failed') {
          _error = next.error ?? '내보내기에 실패했습니다';
        } else if (next.state == 'canceled') {
          _notice = '내보내기를 취소했습니다';
        }
      }
    } on BridgeException catch (error) {
      _error = error.message;
    } catch (error) {
      _error = '진행률을 반영하지 못했습니다: $error';
    }
    notifyListeners();
  }

  Future<String> _defaultExportPath() async {
    final Directory directory = await getApplicationDocumentsDirectory();
    final String stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '')
        .replaceAll('-', '');
    final String extension = _lastPlan?.container ?? 'mp4';
    return '${directory.path}/muud-edits-export-$stamp.$extension';
  }

  Map<String, dynamic> _mapOf(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
    }
    return const <String, dynamic>{};
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _progressSub = null;
    super.dispose();
  }

  void setExportPlatform(String platformId) {
    _exportPlatform = platformId;
    _lastPlan = null;
    notifyListeners();
  }

  Future<void> saveProject(String path) {
    return _mutate(
      () => _bridge.saveProject(stateJson: stateJson, path: path),
      successNotice: '저장했습니다',
    );
  }

  Future<void> saveSubtitles(String path) {
    // 이 호출은 상태를 바꾸지 않는다(자막 파일만 쓴다).
    return _sideEffect(
      () => _bridge.saveSubtitlesSrt(stateJson: stateJson, path: path),
      successNotice: '자막을 저장했습니다',
    );
  }

  /// 상태를 바꾸지 않는 호출(파일 쓰기 등).
  Future<void> _sideEffect(
    Future<String> Function() call, {
    String? successNotice,
  }) async {
    if (_state == null) {
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final String raw = await call();
      final Map<String, dynamic> envelope = _decodeEnvelope(raw);
      if (envelope['ok'] == false) {
        throw _bridgeErrorFrom(envelope);
      }
      if (successNotice != null) {
        _notice = successNotice;
      }
    } on BridgeException catch (error) {
      _error = error.message;
    } catch (error) {
      _error = '$error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Map<String, dynamic> _decodeEnvelope(String text) {
    if (text.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    final Object? decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
    }
    return const <String, dynamic>{};
  }

  BridgeException _bridgeErrorFrom(Map<String, dynamic> envelope) {
    final Object? raw = envelope['error'];
    if (raw is Map<String, dynamic>) {
      return BridgeException(
        raw['code'] is String ? raw['code'] as String : 'unknown',
        raw['message'] is String ? raw['message'] as String : '호출에 실패했습니다',
      );
    }
    return BridgeException('unknown', '호출에 실패했습니다');
  }

  // ---------------------------------------------------------------- UI state

  void selectClip(String? clipId) {
    if (_selectedClipId == clipId) {
      return;
    }
    _selectedClipId = clipId;
    notifyListeners();
  }

  void setPlayhead(int ms) {
    final int limit = durationMs;
    final int next = ms < 0 ? 0 : (limit > 0 && ms > limit ? limit : ms);
    if (next == _playheadMs) {
      return;
    }
    _playheadMs = next;
    notifyListeners();
  }

  void stepFrames(int frames) => setPlayhead(_playheadMs + frames * frameMs);

  void clearMessages() {
    if (_error == null && _notice == null) {
      return;
    }
    _error = null;
    _notice = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ helpers

  String _trackIdForKind(String kind) {
    final EditorState? current = _state;
    if (current == null) {
      return '';
    }
    final String wanted = kind == 'audio' ? 'audio' : 'video';
    for (final TrackView track in current.tracks) {
      if (track.kind == wanted) {
        return track.id;
      }
    }
    return current.tracks.isEmpty ? '' : current.tracks.first.id;
  }

  Future<void> _mutate(
    Future<String> Function() call, {
    String? successNotice,
  }) async {
    if (_state == null) {
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final String raw = await call();
      final EditorState next = EditorState.fromEnvelope(raw);
      _state = next;
      if (_playheadMs > next.durationMs) {
        _playheadMs = next.durationMs;
      }
      if (_selectedClipId != null && next.findClip(_selectedClipId!) == null) {
        _selectedClipId = null;
      }
      if (successNotice != null) {
        _notice = successNotice;
      }
    } on BridgeException catch (error) {
      _error = error.message;
    } catch (error) {
      _error = '$error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
