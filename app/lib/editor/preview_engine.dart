import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../bridge_api.dart';
import '../models.dart';

/// 미리보기에서 **지금 재생해야 하는 것**.
///
/// 타임라인 시각 하나로 결정된다(순수 함수 [resolvePreviewSelection]).
/// UI와 재생 엔진이 같은 계산을 쓰므로, 트림·분할·다중 클립이 있어도
/// "지금 보여야 하는 프레임"이 어긋나지 않는다.
@immutable
class PreviewSelection {
  const PreviewSelection({
    this.visualClip,
    this.audioClip,
    this.sourceMs = 0,
    this.opacity = 1,
    this.volume = 1,
    this.audioVolume = 1,
    this.isGap = true,
  });

  /// 화면에 그릴 영상/이미지 클립(가장 위 트랙).
  final ClipView? visualClip;

  /// 별도 오디오 트랙에서 이 시각에 재생할 클립.
  final ClipView? audioClip;

  /// [visualClip] 안에서의 소스 시각(ms).
  final int sourceMs;

  final double opacity;

  /// 영상 클립의 볼륨(트랙 음소거 반영).
  final double volume;

  /// 오디오 클립의 볼륨(트랙 음소거 반영).
  final double audioVolume;

  /// 이 시각에 영상 클립이 없는 구간(빈 구간)인가.
  final bool isGap;

  bool get hasVisual => visualClip != null;

  String? get visualPath {
    final ClipView? clip = visualClip;
    if (clip == null || clip.sourcePath.trim().isEmpty) {
      return null;
    }
    return clip.sourcePath;
  }

  String? get audioPath {
    final ClipView? clip = audioClip;
    if (clip == null || clip.sourcePath.trim().isEmpty) {
      return null;
    }
    return clip.sourcePath;
  }
}

/// 타임라인 시각 → 소스 시각(코어 `Clip::source_time_at`과 같은 규칙).
int sourceTimeFor(ClipView clip, int atMs) {
  final int delta = atMs - clip.offsetMs;
  final int safeDelta = delta < 0 ? 0 : delta;
  final double speed = clip.speed <= 0 ? 1 : clip.speed;
  final int scaled = (safeDelta * speed).round();
  final int raw = clip.startMs + scaled;
  final int last = clip.endMs <= clip.startMs ? clip.startMs : clip.endMs - 1;
  if (raw < clip.startMs) {
    return clip.startMs;
  }
  return raw > last ? last : raw;
}

/// 소스 시각 → 타임라인 시각(플레이어 위치를 타임라인으로 되돌릴 때).
int timelineTimeFor(ClipView clip, int sourceMs) {
  final int delta = sourceMs - clip.startMs;
  final int safeDelta = delta < 0 ? 0 : delta;
  final double speed = clip.speed <= 0 ? 1 : clip.speed;
  return clip.offsetMs + (safeDelta / speed).round();
}

/// 재생 헤드에 보여야 하는 클립들을 고른다.
///
/// * 영상/이미지: 위쪽 트랙 우선(합성 순서의 역순). 숨긴 트랙·비활성 클립 제외.
/// * 오디오: 별도 오디오 트랙에서 재생 중인 클립(있으면 함께 재생).
PreviewSelection resolvePreviewSelection(EditorState state, int atMs) {
  ClipView? visual;
  double opacity = 1;
  double volume = 1;
  for (final TrackView track in state.tracks.reversed) {
    if (track.hidden || track.kind == 'audio') {
      continue;
    }
    for (final ClipView clip in track.clips) {
      if (!clip.enabled || !clip.contains(atMs)) {
        continue;
      }
      if (clip.kind == 'video' || clip.kind == 'image') {
        visual = clip;
        opacity = clip.opacity;
        volume = track.muted ? 0 : clip.volume;
        break;
      }
    }
    if (visual != null) {
      break;
    }
  }

  ClipView? audio;
  double audioVolume = 1;
  for (final TrackView track in state.tracks) {
    if (track.kind != 'audio' || track.hidden) {
      continue;
    }
    for (final ClipView clip in track.clips) {
      if (!clip.enabled || !clip.contains(atMs)) {
        continue;
      }
      audio = clip;
      audioVolume = track.muted ? 0 : clip.volume;
      break;
    }
    if (audio != null) {
      break;
    }
  }

  return PreviewSelection(
    visualClip: visual,
    audioClip: audio,
    sourceMs: visual == null ? 0 : sourceTimeFor(visual, atMs),
    opacity: opacity.clamp(0.0, 1.0),
    volume: volume.clamp(0.0, 1.0),
    audioVolume: audioVolume.clamp(0.0, 1.0),
    isGap: visual == null,
  );
}

/// 재생 표면(플랫폼 플러그인) 추상화.
///
/// 테스트에서는 [FakePreviewMediaFactory]로 바꿔 네이티브 없이
/// 재생·시크·클립 전환을 검증한다.
abstract class PreviewMedia {
  String get path;

  /// 첫 프레임이 준비됐는가.
  bool get isReady;

  /// 마지막으로 알려진 소스 재생 위치(ms). 준비 전에는 0.
  int get positionMs;

  /// 영상 가로/세로 비율. 모르면 0.
  double get aspectRatio;

  /// 이 미디어에 영상 트랙이 있는가(오디오 전용이면 false).
  bool get hasVideo;

  Future<void> play();

  Future<void> pause();

  Future<void> seekTo(int sourceMs);

  Future<void> setVolume(double volume);

  Future<void> setSpeed(double speed);

  Widget buildSurface();

  Future<void> dispose();
}

/// 경로 하나를 재생 가능한 미디어로 연다.
abstract class PreviewMediaFactory {
  Future<PreviewMedia> open(String path, {required bool wantVideo});
}

/// `video_player` 기반 실제 구현.
///
/// Android는 ExoPlayer, iOS/macOS는 AVFoundation, Windows는 Media Foundation
/// (`video_player_win`)을 쓴다. 세 플랫폼 모두 오디오를 함께 재생한다.
class VideoPlayerMediaFactory implements PreviewMediaFactory {
  const VideoPlayerMediaFactory();

  @override
  Future<PreviewMedia> open(String path, {required bool wantVideo}) async {
    final VideoPlayerPreviewMedia media = VideoPlayerPreviewMedia(path);
    try {
      await media.initialize();
    } catch (error) {
      await media.dispose();
      rethrow;
    }
    return media;
  }
}

/// `video_player` 컨트롤러 하나를 감싼다.
class VideoPlayerPreviewMedia implements PreviewMedia {
  VideoPlayerPreviewMedia(this.path)
    : _controller = VideoPlayerController.file(File(path));

  @override
  final String path;

  final VideoPlayerController _controller;
  bool _ready = false;
  double _volume = 1;
  double _speed = 1;

  Future<void> initialize() async {
    await _controller.initialize();
    final VideoPlayerValue value = _controller.value;
    if (value.hasError) {
      throw PreviewMediaException(
        value.errorDescription ?? '이 파일을 재생할 수 없습니다',
      );
    }
    _ready = true;
  }

  @override
  bool get isReady => _ready && _controller.value.isInitialized;

  @override
  int get positionMs => _controller.value.position.inMilliseconds;

  @override
  double get aspectRatio {
    final double ratio = _controller.value.aspectRatio;
    if (ratio.isNaN || ratio.isInfinite || ratio <= 0) {
      return 0;
    }
    return ratio;
  }

  @override
  bool get hasVideo => _controller.value.size.width > 0;

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> seekTo(int sourceMs) {
    final int durationMs = _controller.value.duration.inMilliseconds;
    int target = sourceMs < 0 ? 0 : sourceMs;
    if (durationMs > 0 && target >= durationMs) {
      target = durationMs - 1 < 0 ? 0 : durationMs - 1;
    }
    return _controller.seekTo(Duration(milliseconds: target));
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _controller.setVolume(_volume);
  }

  @override
  Future<void> setSpeed(double speed) async {
    final double next = speed <= 0 ? 1 : speed.clamp(0.25, 4.0);
    if ((next - _speed).abs() < 0.01) {
      return;
    }
    _speed = next;
    await _controller.setPlaybackSpeed(next);
  }

  @override
  Widget buildSurface() => VideoPlayer(_controller);

  @override
  Future<void> dispose() async {
    _ready = false;
    await _controller.dispose();
  }
}

/// 미리보기 재생 실패.
class PreviewMediaException implements Exception {
  const PreviewMediaException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 타임라인 재생 엔진.
///
/// ## 왜 필요한가
/// 플랫폼 플레이어는 **파일 하나**만 재생한다. 타임라인은 트림·분할·다중 클립·
/// 빈 구간·별도 오디오 트랙의 조합이므로, "지금 재생 헤드에 해당하는 클립"을
/// 계산해 플레이어를 그 클립의 소스 시각으로 옮겨야 한다.
///
/// ## 시간 규칙
/// * 타임라인 시각은 **벽시계 1배**로 흐른다(클립 speed는 소스 시각에만 반영).
/// * 재생 중 플레이어가 멈추거나 밀리면(`DRIFT_LIMIT_MS` 이상) 다시 시크한다.
/// * 사용자가 스크럽하면(플레이헤드가 갑자기 바뀜) 즉시 해당 클립/프레임으로 이동한다.
class PreviewEngine extends ChangeNotifier {
  PreviewEngine({
    required EditorController controller,
    PreviewMediaFactory? mediaFactory,
    int Function()? clockMs,
    this.tickInterval = const Duration(milliseconds: 20),
  }) : _controller = controller,
       _factory = mediaFactory ?? const VideoPlayerMediaFactory(),
       _clockMs =
           clockMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _controller.addListener(_onControllerChanged);
  }

  /// 재생 중 플레이어와 타임라인의 허용 오차.
  static const int driftLimitMs = 450;

  /// 스크럽 시 "이미 그 위치"로 볼 허용 오차.
  static const int seekThresholdMs = 90;

  final EditorController _controller;
  final PreviewMediaFactory _factory;
  final int Function() _clockMs;

  /// 플레이헤드 전진 주기(약 50fps).
  final Duration tickInterval;

  PreviewMedia? _visual;
  PreviewMedia? _audio;
  String? _visualPath;
  String? _audioPath;

  /// [_visual]이 준비 중일 때의 세대 번호(뒤늦게 도착한 열기를 버린다).
  int _openGeneration = 0;

  bool _playing = false;
  bool _opening = false;
  bool _disposed = false;
  int _anchorTimeline = 0;
  int _anchorClock = 0;
  Timer? _ticker;
  String? _error;
  int _pendingSeekMs = -1;
  bool _seekInFlight = false;

  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  bool get isPlaying => _playing;

  bool get isLoading => _opening;

  String? get error => _error;

  /// 지금 화면에 그릴 클립(없으면 빈 구간).
  PreviewSelection get selection {
    final EditorState? state = _controller.state;
    if (state == null) {
      return const PreviewSelection();
    }
    return resolvePreviewSelection(state, _controller.playheadMs);
  }

  /// 재생 표면이 갱신될 때마다 증가(위젯이 구독).
  ValueListenable<int> get repaint => _repaint;

  /// 현재 클립의 영상 표면. 영상이 없으면 null.
  Widget? get surface {
    final PreviewMedia? media = _visual;
    if (media == null || !media.isReady || !media.hasVideo) {
      return null;
    }
    return media.buildSurface();
  }

  /// 현재 클립의 영상 비율(표면이 없으면 0).
  double get surfaceAspectRatio {
    final PreviewMedia? media = _visual;
    if (media == null || !media.isReady) {
      return 0;
    }
    return media.aspectRatio;
  }

  /// 이미지 클립이면 그 경로(프리뷰에서 정지 이미지로 그린다).
  String? get imagePath {
    final PreviewSelection sel = selection;
    final ClipView? clip = sel.visualClip;
    if (clip == null || clip.kind != 'image' || clip.sourcePath.isEmpty) {
      return null;
    }
    return clip.sourcePath;
  }

  // ------------------------------------------------------------------ 재생 제어

  void togglePlay() {
    if (_playing) {
      pause();
    } else {
      play();
    }
  }

  void play() {
    if (_playing || _disposed) {
      return;
    }
    final int total = _controller.durationMs;
    if (total <= 0) {
      return;
    }
    if (_controller.playheadMs >= total) {
      _controller.setPlayhead(0);
    }
    _error = null;
    _playing = true;
    _anchorTimeline = _controller.playheadMs;
    _anchorClock = _clockMs();
    _ticker?.cancel();
    _ticker = Timer.periodic(tickInterval, (_) => _onTick());
    unawaited(_sync(force: true));
    notifyListeners();
  }

  void pause() {
    if (!_playing) {
      return;
    }
    _playing = false;
    _ticker?.cancel();
    _ticker = null;
    unawaited(_safeCall(() async {
      await _visual?.pause();
      await _audio?.pause();
    }));
    notifyListeners();
  }

  /// 사용자가 재생 헤드를 옮겼을 때(스크럽·탭·프레임 이동).
  ///
  /// 화면은 이미 [EditorController.setPlayhead]로 값을 바꿨으므로, 여기서는
  /// 재생 중이면 기준 시각만 다시 잡는다. 실제 시크는 [_sync]가 한다.
  void _reanchor() {
    _anchorTimeline = _controller.playheadMs;
    _anchorClock = _clockMs();
  }

  void _onTick() {
    if (!_playing || _disposed) {
      return;
    }
    final int elapsed = _clockMs() - _anchorClock;
    final int total = _controller.durationMs;
    int next = _anchorTimeline + (elapsed < 0 ? 0 : elapsed);
    if (total > 0 && next >= total) {
      next = total;
      _controller.setPlayhead(next);
      pause();
      return;
    }
    _controller.setPlayhead(next);
  }

  // ------------------------------------------------------------------ 동기화

  void _onControllerChanged() {
    if (_disposed) {
      return;
    }
    // 재생 중 사용자가 헤드를 옮겼으면 벽시계 기준도 함께 옮긴다.
    if (_playing) {
      final int elapsed = _clockMs() - _anchorClock;
      final int expected = _anchorTimeline + (elapsed < 0 ? 0 : elapsed);
      if ((expected - _controller.playheadMs).abs() > 120) {
        _reanchor();
      }
    }
    unawaited(_sync());
  }

  /// 현재 상태에 맞춰 플레이어를 맞춘다.
  Future<void> _sync({bool force = false}) async {
    if (_disposed) {
      return;
    }
    final EditorState? state = _controller.state;
    if (state == null) {
      return;
    }
    final int atMs = _controller.playheadMs;
    final PreviewSelection sel = resolvePreviewSelection(state, atMs);

    await _reconcileVisual(sel);
    await _reconcileAudio(sel);

    if (_visual == null && _audio == null) {
      return;
    }

    // 영상 위치 맞추기.
    final PreviewMedia? visual = _visual;
    if (visual != null && visual.isReady && sel.visualClip != null) {
      await _syncPosition(
        media: visual,
        clip: sel.visualClip!,
        targetSourceMs: sel.sourceMs,
        force: force,
      );
      await _safeCall(() => visual.setVolume(sel.volume));
      await _safeCall(() => visual.setSpeed(sel.visualClip!.speed));
      if (_playing) {
        await _safeCall(() => visual.play());
      }
    }

    // 별도 오디오 클립도 같은 타임라인 시각으로 맞춘다.
    final PreviewMedia? audio = _audio;
    if (audio != null && audio.isReady && sel.audioClip != null) {
      await _syncPosition(
        media: audio,
        clip: sel.audioClip!,
        targetSourceMs: sourceTimeFor(sel.audioClip!, atMs),
        force: force,
      );
      await _safeCall(() => audio.setVolume(sel.audioVolume));
      await _safeCall(() => audio.setSpeed(sel.audioClip!.speed));
      if (_playing) {
        await _safeCall(() => audio.play());
      }
    }

    if (!_playing) {
      await _safeCall(() async {
        await visual?.pause();
        await audio?.pause();
      });
    }
  }

  /// 대상 클립이 바뀌었으면 플레이어를 새로 연다.
  Future<void> _reconcileVisual(PreviewSelection sel) async {
    final ClipView? clip = sel.visualClip;
    final String? rawPath = sel.visualPath;
    final String? path = (clip != null &&
            clip.kind == 'video' &&
            rawPath != null &&
            rawPath.isNotEmpty)
        ? rawPath
        : null;

    if (path == null) {
      // 이미지 클립이거나 빈 구간: 영상 플레이어는 내려놓는다.
      if (_visual != null) {
        await _closeVisual();
      }
      return;
    }
    if (_visual != null && _visualPath == path) {
      return;
    }
    await _closeVisual();
    final int generation = ++_openGeneration;
    _opening = true;
    notifyListeners();
    try {
      final PreviewMedia media = await _factory.open(path, wantVideo: true);
      if (_disposed || generation != _openGeneration) {
        await media.dispose();
        return;
      }
      _visual = media;
      _visualPath = path;
      _error = null;
      _repaint.value++;
    } on Object catch (error) {
      if (generation == _openGeneration) {
        _error = _describe(error);
      }
    } finally {
      if (generation == _openGeneration) {
        _opening = false;
        notifyListeners();
      }
    }
  }

  Future<void> _reconcileAudio(PreviewSelection sel) async {
    final ClipView? clip = sel.audioClip;
    final String? path = sel.audioPath;
    if (clip == null || path == null) {
      if (_audio != null) {
        await _closeAudio();
      }
      return;
    }
    if (_audio != null && _audioPath == path) {
      return;
    }
    await _closeAudio();
    try {
      final PreviewMedia media = await _factory.open(path, wantVideo: false);
      if (_disposed) {
        await media.dispose();
        return;
      }
      _audio = media;
      _audioPath = path;
      _repaint.value++;
    } on Object catch (error) {
      _error ??= _describe(error);
    }
  }

  /// 플레이어 위치를 목표 소스 시각에 맞춘다(드리프트/스크럽).
  Future<void> _syncPosition({
    required PreviewMedia media,
    required ClipView clip,
    required int targetSourceMs,
    required bool force,
  }) async {
    if (_seekInFlight) {
      _pendingSeekMs = targetSourceMs;
      return;
    }
    final int current = media.positionMs;
    final bool far = (current - targetSourceMs).abs() > seekThresholdMs;
    final bool stalled = _playing &&
        (current - targetSourceMs).abs() > driftLimitMs;
    if (!force && !far && !stalled) {
      return;
    }
    _seekInFlight = true;
    try {
      await media.seekTo(targetSourceMs);
    } on Object catch (error) {
      _error ??= _describe(error);
    } finally {
      _seekInFlight = false;
      final int pending = _pendingSeekMs;
      _pendingSeekMs = -1;
      if (pending >= 0 && (pending - targetSourceMs).abs() > seekThresholdMs) {
        await _syncPosition(
          media: media,
          clip: clip,
          targetSourceMs: pending,
          force: true,
        );
      }
    }
  }

  Future<void> _closeVisual() async {
    final PreviewMedia? media = _visual;
    _visual = null;
    _visualPath = null;
    _openGeneration++;
    _repaint.value++;
    if (media != null) {
      await _safeCall(media.dispose);
    }
  }

  Future<void> _closeAudio() async {
    final PreviewMedia? media = _audio;
    _audio = null;
    _audioPath = null;
    _repaint.value++;
    if (media != null) {
      await _safeCall(media.dispose);
    }
  }

  Future<void> _safeCall(Future<void> Function() body) async {
    try {
      await body();
    } on Object catch (error) {
      _error ??= _describe(error);
    }
  }

  String _describe(Object error) {
    if (error is PreviewMediaException) {
      return error.message;
    }
    final String text = '$error';
    return text.isEmpty ? '미리보기를 재생할 수 없습니다' : text;
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    _controller.removeListener(_onControllerChanged);
    final PreviewMedia? visual = _visual;
    final PreviewMedia? audio = _audio;
    _visual = null;
    _audio = null;
    unawaited(visual?.dispose() ?? Future<void>.value());
    unawaited(audio?.dispose() ?? Future<void>.value());
    _repaint.dispose();
    super.dispose();
  }
}

/// 테스트용 가짜 미디어. 열린 경로/시크/재생 호출을 기록한다.
class FakePreviewMedia implements PreviewMedia {
  FakePreviewMedia(this.path, {this.video = true, this.aspect = 9 / 16});

  @override
  final String path;

  final bool video;
  final double aspect;

  bool ready = true;
  bool playing = false;
  int position = 0;
  int seekCount = 0;
  double volume = 1;
  double speed = 1;
  bool disposed = false;

  @override
  bool get isReady => ready;

  @override
  int get positionMs => position;

  @override
  double get aspectRatio => aspect;

  @override
  bool get hasVideo => video;

  @override
  Future<void> play() async {
    playing = true;
  }

  @override
  Future<void> pause() async {
    playing = false;
  }

  @override
  Future<void> seekTo(int sourceMs) async {
    position = sourceMs;
    seekCount++;
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
  }

  @override
  Widget buildSurface() => const SizedBox.shrink();

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 테스트용 팩토리. 경로별 가짜 미디어를 돌려주고 열린 순서를 기록한다.
class FakePreviewMediaFactory implements PreviewMediaFactory {
  FakePreviewMediaFactory({this.fail = false});

  final bool fail;
  final List<String> opened = <String>[];
  final Map<String, FakePreviewMedia> media = <String, FakePreviewMedia>{};

  @override
  Future<PreviewMedia> open(String path, {required bool wantVideo}) async {
    opened.add(path);
    if (fail) {
      throw const PreviewMediaException('테스트: 재생할 수 없음');
    }
    final FakePreviewMedia item = FakePreviewMedia(path, video: wantVideo);
    media[path] = item;
    return item;
  }
}
