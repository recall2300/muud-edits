import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
    this.audioFromVideoTrack = false,
    this.sourceMs = 0,
    this.opacity = 1,
    this.volume = 1,
    this.audioVolume = 1,
    this.isGap = true,
  });

  /// 화면에 그릴 영상/이미지 클립(가장 위 트랙).
  final ClipView? visualClip;

  /// 이 시각에 들려야 하는 소리의 클립.
  ///
  /// 우선순위: 별도 오디오 트랙 클립 → (화면이 이미지일 때) 아래 비디오 트랙의
  /// 영상 클립. 화면이 영상이면 그 영상이 자기 소리를 내므로 null 이다.
  final ClipView? audioClip;

  /// [audioClip]이 비디오 트랙에서 온 것인가(위에 이미지가 얹혔을 때).
  final bool audioFromVideoTrack;

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

/// 미리보기에서 낼 수 있는 최대 볼륨.
///
/// 클립 볼륨은 프로젝트에서 2.0까지 열려 있지만, `video_player` 는 플랫폼
/// 믹서를 통해 1.0을 넘는 값을 재생하지 못한다. 1.0을 넘는 값은 미리보기에서만
/// 1.0으로 제한하고, 내보내기(플랫폼 렌더러)는 그래프의 gain 을 그대로 쓴다.
const double previewVolumeCeiling = 1.0;

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

  // 1) 별도 오디오 트랙의 클립이 있으면 그것이 소리다.
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

  // 2) 소리가 없고 화면이 이미지라면, 그 아래 영상 클립의 소리를 살린다.
  //    (예전에는 위 트랙에서 이미지를 고르는 순간 아래 영상의 오디오까지 사라졌다.)
  bool audioFromVideo = false;
  if (audio == null && (visual == null || visual.kind != 'video')) {
    for (final TrackView track in state.tracks.reversed) {
      if (track.hidden || track.kind == 'audio') {
        continue;
      }
      for (final ClipView clip in track.clips) {
        if (!clip.enabled || !clip.contains(atMs) || clip.kind != 'video') {
          continue;
        }
        if (clip.id == visual?.id) {
          continue;
        }
        audio = clip;
        audioFromVideo = true;
        audioVolume = track.muted ? 0 : clip.volume;
        break;
      }
      if (audio != null) {
        break;
      }
    }
  }

  return PreviewSelection(
    visualClip: visual,
    audioClip: audio,
    audioFromVideoTrack: audioFromVideo,
    sourceMs: visual == null ? 0 : sourceTimeFor(visual, atMs),
    opacity: opacity.clamp(0.0, 1.0),
    volume: volume.clamp(0.0, previewVolumeCeiling),
    audioVolume: audioVolume.clamp(0.0, previewVolumeCeiling),
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
    // 이미 그 위치라면 다시 시크하지 않는다(플랫폼에 따라 재탐색이 일어난다).
    if ((_controller.value.position.inMilliseconds - target).abs() < 8) {
      return Future<void>.value();
    }
    return _controller.seekTo(Duration(milliseconds: target));
  }

  @override
  Future<void> setVolume(double volume) async {
    final double next = volume.clamp(0.0, 1.0);
    if ((next - _volume).abs() < 0.001) {
      return;
    }
    _volume = next;
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

/// 플레이어가 알려 주는 위치(약 100ms 간격)를 플레이헤드의 매끄러운 시계로 잇는다.
///
/// 플레이어 위치를 그대로 쓰면 30fps 미리보기가 10fps로 끊겨 보인다. 그래서
/// **마지막으로 받은 위치 + 흐른 시간**으로 잇고, 새 위치가 오면 그 값에 다시
/// 붙인다. 플레이어가 멈추면(버퍼링 등) 앞서 달리지 않도록
/// [maxExtrapolationMs]까지만 앞선다.
class MediaPositionClock {
  MediaPositionClock({
    this.maxExtrapolationMs = 160,
    this.maxReportGapMs = 400,
    this.maxStepBackMs = 250,
  });

  /// 한 번의 보고 사이에서 앞서 추정하는 **최소** 한도(ms).
  final int maxExtrapolationMs;

  /// 보고 간격이 길어질 때 보간 상한을 늘려 줄 수 있는 절대 한계(ms).
  final int maxReportGapMs;

  /// 이보다 작게 뒤로 간 보고는 잔떨림으로 보고 무시한다.
  final int maxStepBackMs;

  int _anchorSource = 0;
  int _anchorClock = 0;
  int _lastRaw = -1;
  int _lastValue = 0;
  int _reportIntervalMs = 0;
  bool _primed = false;

  /// 지금 보고 주기에서 허용하는 앞섬 한도(ms).
  ///
  /// 플러그인은 100ms 간격으로 위치를 보고하지만, 플랫폼 채널 왕복이 밀리면
  /// 간격이 그보다 길어진다. 상한을 160ms 로 고정해 두면 간격이 160ms 를 넘는
  /// 순간 플레이헤드가 **멈췄다가 다음 보고에서 점프**해, 재생이 끊긴 것처럼
  /// 보인다. 그래서 최근 관측한 보고 간격의 두 배까지 상한을 늘린다(최대
  /// [maxReportGapMs]). 플레이어가 정말 멈추면(버퍼링) 이 한도에서 멈춘다.
  int get extrapolationLimitMs {
    final int adaptive = _reportIntervalMs * 2;
    final int limit = math.max(adaptive, maxExtrapolationMs);
    return math.min(limit, maxReportGapMs);
  }

  /// 마지막 계산값(뒤로 가지 않게 하는 기준).
  int get value => _lastValue;

  void reset() {
    _anchorSource = 0;
    _anchorClock = 0;
    _lastRaw = -1;
    _lastValue = 0;
    _reportIntervalMs = 0;
    _primed = false;
  }

  /// 새 위치 보고를 반영하고, 지금 시각이어야 할 소스 위치를 돌려준다.
  int advance(int rawSourceMs, int nowMs) {
    final int raw = rawSourceMs < 0 ? 0 : rawSourceMs;
    if (!_primed) {
      _primed = true;
      _lastRaw = raw;
      _anchorSource = raw;
      _anchorClock = nowMs;
      _lastValue = raw;
      return raw;
    }
    if (raw != _lastRaw) {
      // 새 보고(또는 시크): 그 값에 기준을 다시 붙인다.
      final int interval = nowMs - _anchorClock;
      if (interval > 0 && interval <= maxReportGapMs) {
        _reportIntervalMs = interval;
      }
      _lastRaw = raw;
      _anchorSource = raw;
      _anchorClock = nowMs;
      int next = raw;
      if (next < _lastValue && _lastValue - next < maxStepBackMs) {
        next = _lastValue;
      }
      _lastValue = next;
      return next;
    }
    // 같은 보고가 이어지면 흐른 시간만큼만 앞선다(정지하면 멈춘다).
    int elapsed = nowMs - _anchorClock;
    if (elapsed < 0) {
      elapsed = 0;
    }
    final int limit = extrapolationLimitMs;
    if (elapsed > limit) {
      elapsed = limit;
    }
    final int next = _anchorSource + elapsed;
    if (next > _lastValue) {
      _lastValue = next;
    }
    return _lastValue;
  }
}

/// 타임라인 재생 엔진.
///
/// ## 왜 필요한가
/// 플랫폼 플레이어는 **파일 하나**만 재생한다. 타임라인은 트림·분할·다중 클립·
/// 빈 구간·별도 오디오 트랙의 조합이므로, "지금 재생 헤드에 해당하는 클립"을
/// 계산해 플레이어를 그 클립의 소스 시각으로 옮겨야 한다.
///
/// ## 시간 규칙 (끊김 없이 이어 재생하기)
/// * **재생 중에는 플레이어가 시계다.** 영상/오디오를 실제로 재생하고 있으면
///   플레이어가 알려 주는 위치를 타임라인 시각으로 되돌려 플레이헤드를 옮긴다
///   ([MediaPositionClock]으로 100ms 보고 사이를 벽시계로 잇는다).
/// * **빈 구간·이미지 클립에서만 벽시계**로 플레이헤드를 흘린다.
/// * **같은 클립을 이어 재생하는 동안에는 시크하지 않는다.** 시크는 사용자가
///   위치를 옮겼을 때(스크럽·탭·프레임 이동)와 클립이 바뀌었을 때만 한다.
/// * 재생 중에는 [EditorController]의 플레이헤드를 매 프레임 바꾸지 않는다
///   (화면 전체가 리빌드되면 프레임이 떨어진다). 위치는 [position] 노티파이어로
///   알리고, 편집 동작이나 일시정지 시점에 컨트롤러로 커밋한다.
class PreviewEngine extends ChangeNotifier {
  PreviewEngine({
    required EditorController controller,
    PreviewMediaFactory? mediaFactory,
    int Function()? clockMs,
    this.tickInterval = const Duration(milliseconds: 33),
  }) : _controller = controller,
       _factory = mediaFactory ?? const VideoPlayerMediaFactory(),
       _clockMs = clockMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _position.value = controller.playheadMs;
    _lastState = controller.state;
    _controller.addListener(_onControllerChanged);
  }

  /// 일시정지 상태에서 스크럽 위치와 플레이어 위치가 이만큼 벌어지면 시크한다.
  static const int scrubSeekThresholdMs = 90;

  /// 새로 연 미디어의 첫 시크를 건너뛸 수 있는 오차(이미 그 위치면 재탐색이
  /// 오히려 끊김을 만든다).
  static const int freshSeekSlackMs = 40;

  /// 재생 중 같은 클립 안에서 허용하는 오차. 이보다 크게 벌어졌을 때만(예: 기기
  /// 절전으로 플레이어가 오래 멈춘 경우) 플레이어를 다시 맞춘다.
  static const int playingSlackMs = 1200;

  /// 시크 직후 플랫폼 보고를 믿기까지의 여유(ms).
  ///
  /// 플랫폼 플레이어는 시크를 받은 직후에도 잠시 **이전 위치(0)** 를 보고한다.
  /// 그 값을 재생 시계에 그대로 넣으면 플레이헤드가 인점보다 앞(0ms)으로 튀었다가
  /// 다음 보고에서 되돌아와, 트림된 클립의 첫 시크가 "0ms 에서 멈춤/점프"로 보인다.
  static const int seekHoldToleranceMs = 200;

  /// 시크 보고를 기다리는 최대 시간(ms). 넘으면 보고를 그대로 받아들인다.
  static const int seekHoldTimeoutMs = 1500;

  /// 다음 클립을 미리 열기 시작하는 남은 시간(ms).
  static const int preloadLeadMs = 1500;

  final EditorController _controller;
  final PreviewMediaFactory _factory;
  final int Function() _clockMs;

  /// 플레이헤드/플레이어 위치 확인 주기(약 30fps).
  final Duration tickInterval;

  PreviewMedia? _visual;
  PreviewMedia? _audio;
  String? _visualPath;
  String? _audioPath;
  String? _visualClipId;
  String? _audioClipId;

  /// 새로 연 미디어는 첫 동기화에서 목표 위치로 시크한다.
  bool _freshVisual = false;
  bool _freshAudio = false;

  /// 이미 play()를 보냈는가(매 틱 플랫폼 호출을 하지 않기 위해).
  bool _visualStarted = false;
  bool _audioStarted = false;

  /// 플레이어 위치 → 타임라인 시각을 잇는 시계.
  final MediaPositionClock _visualClock = MediaPositionClock();
  final MediaPositionClock _audioClock = MediaPositionClock();

  /// [_visual]이 준비 중일 때의 세대 번호(뒤늦게 도착한 열기를 버린다).
  int _openGeneration = 0;
  bool _openingVisual = false;
  bool _openingAudio = false;

  /// 다음 클립을 미리 열어 둔 것(전환 지연 최소화).
  Future<PreviewMedia?>? _preload;
  String? _preloadPath;
  String? _preloadFailedPath;

  EditorState? _lastState;
  bool _playing = false;
  bool _syncScheduled = false;
  bool _syncForceSeek = false;
  bool _disposed = false;
  bool _applyingPlayhead = false;
  int _wallAnchorTimeline = 0;
  int _wallAnchorClock = 0;
  Timer? _ticker;
  String? _error;
  int _pendingSeekMs = -1;
  bool _seekInFlight = false;

  /// 시크 목표(영상 플레이어). 플랫폼이 이 위치에 도달하기 전 보고는 무시한다.
  int _visualHoldMs = -1;
  int _visualHoldDeadlineMs = 0;

  /// [_sync] 가 실행 중인가(겹쳐 들어온 요청은 한 번만 더 돌린다).
  bool _syncInFlight = false;
  bool _syncAgain = false;
  bool _syncAgainForceSeek = false;

  /// 마지막으로 플레이어를 정렬한 선택과 상태.
  ///
  /// 재생 중 매 틱 플랫폼을 건드리지 않으려면 "무엇이 바뀌었는지"를 이 값과
  /// 비교해야 한다. 같은 클립을 이어 재생하는 동안에는 둘 다 그대로이므로
  /// 틱은 플레이헤드만 옮긴다.
  PreviewSelection? _syncedSelection;
  EditorState? _syncedState;

  /// 열기에 실패한 경로(같은 경로를 매 프레임 다시 열지 않는다).
  String? _failedVisualPath;
  String? _failedAudioPath;

  final ValueNotifier<int> _position = ValueNotifier<int>(0);
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  bool get isPlaying => _playing;

  bool get isLoading => _openingVisual;

  String? get error => _error;

  /// 재생 중 매 프레임 바뀌는 재생 헤드(ms).
  ///
  /// 화면은 이 값만 [ValueListenableBuilder]로 구독해 타임코드·플레이헤드 선만
  /// 다시 그린다.
  ValueListenable<int> get position => _position;

  /// 지금 재생 헤드 시각(ms).
  int get positionMs => _position.value;

  /// 지금 화면에 그릴 클립(없으면 빈 구간).
  PreviewSelection get selection {
    final EditorState? state = _controller.state;
    if (state == null) {
      return const PreviewSelection();
    }
    return resolvePreviewSelection(state, _position.value);
  }

  /// 재생 표면이 갱신될 때마다 증가(위젯이 구독).
  ValueListenable<int> get repaint => _repaint;

  /// 현재 클립의 영상 표면. 영상이 없으면 null.
  ///
  /// 빈 구간에서는 플레이어를 살려 두지만(재진입 비용 절감) 화면에는 아무것도
  /// 그리지 않는다. 빈 구간 안내는 프리뷰 패널이 대신 보여 준다.
  Widget? get surface {
    if (selection.visualClip == null) {
      return null;
    }
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
    if (_position.value >= total) {
      _setPosition(0);
      _commitToController(0);
    }
    _error = null;
    // 이전에 열지 못한 파일도 다시 시도한다.
    _failedVisualPath = null;
    _failedAudioPath = null;
    // 재생을 시작하면 플레이어를 다시 한 번 정렬한다(아래 _sync).
    _syncedSelection = null;
    _syncedState = null;
    _playing = true;
    _wallAnchorTimeline = _position.value;
    _wallAnchorClock = _clockMs();
    _ticker?.cancel();
    _ticker = Timer.periodic(tickInterval, (_) => _onTick());
    unawaited(_sync());
    notifyListeners();
  }

  void pause() {
    if (_disposed) {
      return;
    }
    final bool wasPlaying = _playing;
    _playing = false;
    _ticker?.cancel();
    _ticker = null;
    _visualStarted = false;
    _audioStarted = false;
    _dropPreload();
    _syncedSelection = null;
    _syncedState = null;
    // 여기서 한 번만 컨트롤러에 알린다(재생 중 매 프레임 알리지 않는다).
    _commitToController(_position.value);
    unawaited(_safeCall(() async {
      await _visual?.pause();
      await _audio?.pause();
    }));
    if (wasPlaying) {
      notifyListeners();
    }
  }

  /// 재생 중인 위치를 [EditorController]의 플레이헤드로 옮겨 적는다.
  ///
  /// 분할·자막 추가·프레임 이동처럼 컨트롤러의 플레이헤드를 읽는 동작 전에
  /// 화면이 호출한다.
  void commitPlayhead() {
    if (_disposed) {
      return;
    }
    _commitToController(_position.value);
  }

  void _commitToController(int ms) {
    if (_disposed) {
      return;
    }
    _applyingPlayhead = true;
    try {
      _controller.setPlayhead(ms);
    } finally {
      _applyingPlayhead = false;
    }
  }

  void _setPosition(int ms) {
    final int next = ms < 0 ? 0 : ms;
    if (_position.value != next) {
      _position.value = next;
    }
  }

  // ------------------------------------------------------------------ 재생 루프

  void _onTick() {
    if (!_playing || _disposed) {
      return;
    }
    final EditorState? state = _controller.state;
    if (state == null) {
      return;
    }
    final int now = _clockMs();
    final int total = _controller.durationMs;
    final int current = _position.value;

    final PreviewSelection currentSelection = resolvePreviewSelection(
      state,
      current,
    );

    // 1) 마스터 시계: 실제로 재생 중인 플레이어 위치(있으면 그것이 기준).
    final int? player = _playerTimelineMs(currentSelection, now);
    int next;
    if (player != null) {
      next = player;
      _wallAnchorTimeline = next;
      _wallAnchorClock = now;
    } else {
      final int elapsed = now - _wallAnchorClock;
      next = _wallAnchorTimeline + (elapsed < 0 ? 0 : elapsed);
    }
    if (next < current) {
      next = current; // 재생 중에는 뒤로 가지 않는다.
    }
    if (total > 0 && next >= total) {
      _setPosition(total);
      _finishPlayback();
      return;
    }
    _setPosition(next);

    // 2) 플레이어 정렬(플랫폼 호출·비동기 체인)은 **바뀐 틱에만** 한다.
    //
    // 같은 클립을 이어 재생하는 동안에는 선택도 상태도 그대로이므로 여기서
    // 아무 일도 일어나지 않는다 — 틱은 플레이헤드만 옮긴다. 매 틱 async
    // 체인을 쌓으면 UI/래스터 프레임이 밀려 영상이 끊긴다.
    final PreviewSelection sel = next == current
        ? currentSelection
        : resolvePreviewSelection(state, next);
    if (_needsSync(state, sel)) {
      unawaited(_sync(sel: sel, atMs: next));
      return;
    }

    // 3) 경계가 가까울 때만 다음 클립을 미리 연다(그 밖에는 아무 일도 없음).
    final ClipView? clip = sel.visualClip;
    if (clip != null && clip.endOffsetMs - next <= preloadLeadMs) {
      _maybePreload(state, sel, next);
    }
  }

  /// 지금 플레이어를 다시 정렬해야 하는가.
  ///
  /// 재생 중 틱마다 플랫폼/비동기 작업을 돌리지 않기 위해, 실제로 무엇이
  /// 바뀌었을 때만 참을 돌려준다.
  bool _needsSync(EditorState state, PreviewSelection sel) {
    // 열기/시크가 진행 중이면 매 프레임 다시 쌓지 않는다(중복 트리거 억제).
    // 열기가 끝나면 [_syncOnce] 가 이 선택을 기록하므로 다음 틱부터 다시 판단한다.
    if (_openingVisual || _openingAudio || _seekInFlight) {
      return false;
    }
    // 클립이 바뀌었거나 빈 구간으로 들어갔다.
    if (!_sameSelection(sel, _syncedSelection)) {
      return true;
    }
    // 편집으로 타임라인 상태가 바뀌었다.
    if (!identical(state, _syncedState)) {
      return true;
    }
    // 새로 연 미디어가 아직 재생 전이다(열기 직후 한 번).
    if (sel.visualPath != null && _visual != null && !_visualStarted) {
      return true;
    }
    if (sel.audioPath != null && _audio != null && !_audioStarted) {
      return true;
    }
    return false;
  }

  /// 재생에 의미 있는 두 선택이 같은가.
  bool _sameSelection(PreviewSelection? a, PreviewSelection? b) {
    if (a == null || b == null) {
      return false;
    }
    return a.visualClip?.id == b.visualClip?.id &&
        a.audioClip?.id == b.audioClip?.id &&
        a.visualPath == b.visualPath &&
        a.audioPath == b.audioPath &&
        a.isGap == b.isGap &&
        (a.volume - b.volume).abs() < 0.001 &&
        (a.audioVolume - b.audioVolume).abs() < 0.001 &&
        (a.opacity - b.opacity).abs() < 0.001;
  }

  /// 재생 중인 플레이어 위치를 타임라인 시각으로 돌려준다(없으면 null).
  int? _playerTimelineMs(PreviewSelection sel, int now) {
    final PreviewMedia? visual = _visual;
    final ClipView? visualClip = sel.visualClip;
    if (visual != null &&
        visual.isReady &&
        _visualStarted &&
        visualClip != null &&
        visualClip.kind == 'video' &&
        _visualClipId == visualClip.id) {
      final int raw = visual.positionMs;
      if (_reportIsStale(raw, now)) {
        // 시크 목표에 아직 도달하지 못한 보고(0 등) — 벽시계로 계속 흐르게 둔다.
        return null;
      }
      final int source = _visualClock.advance(raw, now);
      return timelineTimeFor(visualClip, source);
    }
    final PreviewMedia? audio = _audio;
    final ClipView? audioClip = sel.audioClip;
    if (audio != null &&
        audio.isReady &&
        _audioStarted &&
        audioClip != null &&
        _audioClipId == audioClip.id) {
      final int source = _audioClock.advance(audio.positionMs, now);
      return timelineTimeFor(audioClip, source);
    }
    return null;
  }

  /// 플랫폼이 보고한 위치가 아직 시크 목표에 미치지 못한가.
  ///
  /// 시크 직후 0(또는 이전 위치)을 보고하는 플랫폼이 있다. 그 값을 재생 시계에
  /// 넣으면 트림된 클립의 재생 헤드가 인점보다 앞으로 튄다. 목표에 가까워지면
  /// 그때부터 보고를 신뢰하고, 너무 오래 걸리면(타임아웃) 그냥 받아들인다.
  bool _reportIsStale(int rawSourceMs, int nowMs) {
    if (_visualHoldMs < 0) {
      return false;
    }
    if (rawSourceMs + seekHoldToleranceMs >= _visualHoldMs) {
      _visualHoldMs = -1;
      return false;
    }
    if (nowMs >= _visualHoldDeadlineMs) {
      _visualHoldMs = -1;
      return false;
    }
    return true;
  }

  void _finishPlayback() {    _playing = false;
    _ticker?.cancel();
    _ticker = null;
    _visualStarted = false;
    _audioStarted = false;
    _dropPreload();
    _syncedSelection = null;
    _syncedState = null;
    _commitToController(_position.value);
    unawaited(_safeCall(() async {
      await _visual?.pause();
      await _audio?.pause();
    }));
    notifyListeners();
  }

  // ------------------------------------------------------------------ 동기화

  void _onControllerChanged() {
    if (_disposed || _applyingPlayhead) {
      return;
    }
    final EditorState? state = _controller.state;
    final bool stateChanged = !identical(state, _lastState);
    _lastState = state;
    if (_playing) {
      // 재생 중 플레이헤드는 플레이어가 정한다. 편집으로 상태가 바뀐 경우에만
      // 클립 구성을 다시 맞춘다(시크는 하지 않는다).
      if (stateChanged) {
        _scheduleSync();
      }
      return;
    }
    final int at = _controller.playheadMs;
    if (at != _position.value) {
      _position.value = at;
    }
    // 일시정지 상태의 위치 변경은 사용자의 스크럽이다 → 그 위치로 시크한다.
    _scheduleSync(forceSeek: true);
  }

  void _scheduleSync({bool forceSeek = false}) {
    _syncForceSeek = _syncForceSeek || forceSeek;
    if (_syncScheduled) {
      return;
    }
    _syncScheduled = true;
    scheduleMicrotask(() {
      _syncScheduled = false;
      if (_disposed) {
        return;
      }
      final bool force = _syncForceSeek;
      _syncForceSeek = false;
      unawaited(_sync(forceSeek: force));
    });
  }

  /// 지금 상태에 맞춰 플레이어를 맞춘다.
  ///
  /// [forceSeek]는 사용자가 위치를 옮긴 직후에만 준다. 재생 중에는 이 값이
  /// 없으면 클립이 바뀐 경우(새로 연 미디어)에만 시크한다.
  ///
  /// **동시 실행 금지**: 열기·시크가 겹치면 같은 플레이어에 두 갈래 명령이
  /// 섞여 들어가 재생이 끊긴다. 실행 중에 들어온 요청은 버리지 않고 한 번만
  /// 더 돌린다(최신 상태로 다시 계산).
  Future<void> _sync({
    PreviewSelection? sel,
    int? atMs,
    bool forceSeek = false,
  }) async {
    if (_disposed) {
      return;
    }
    if (_syncInFlight) {
      _syncAgain = true;
      _syncAgainForceSeek = _syncAgainForceSeek || forceSeek;
      return;
    }
    _syncInFlight = true;
    try {
      bool first = true;
      bool force = forceSeek;
      for (int attempt = 0; attempt < 3; attempt++) {
        _syncAgain = false;
        await _syncOnce(
          sel: first ? sel : null,
          atMs: first ? atMs : null,
          forceSeek: force,
        );
        first = false;
        if (_disposed || !_syncAgain) {
          break;
        }
        force = _syncAgainForceSeek;
        _syncAgainForceSeek = false;
      }
    } finally {
      _syncAgain = false;
      _syncAgainForceSeek = false;
      _syncInFlight = false;
    }
  }

  Future<void> _syncOnce({
    PreviewSelection? sel,
    int? atMs,
    bool forceSeek = false,
  }) async {
    if (_disposed) {
      return;
    }
    final EditorState? state = _controller.state;
    if (state == null) {
      return;
    }
    final int at = atMs ?? _position.value;
    final PreviewSelection selection = sel ?? resolvePreviewSelection(state, at);
    final String? beforeVisual = _syncedSelection?.visualClip?.id;

    if (forceSeek) {
      _freshVisual = _visual != null;
      _freshAudio = _audio != null;
    }

    await _reconcileVisual(selection);
    await _reconcileAudio(selection);
    if (_disposed || !identical(state, _controller.state)) {
      return;
    }

    await _syncVisual(state, selection, at);
    await _syncAudio(selection, at);

    if (!_playing) {
      final PreviewMedia? visual = _visual;
      final PreviewMedia? audio = _audio;
      await _safeCall(() async {
        await visual?.pause();
        await audio?.pause();
      });
    }

    // 이 선택으로 플레이어를 맞춘 것을 기록한다(다음 틱은 바뀐 것이 없으면 아무 일도 안 함).
    _syncedSelection = selection;
    _syncedState = state;
    // 화면에 그릴 클립이 바뀌었으면 프리뷰 표면을 다시 그린다(빈 구간 → 검은 화면).
    if (beforeVisual != selection.visualClip?.id) {
      _repaint.value++;
    }
  }

  Future<void> _syncVisual(
    EditorState state,
    PreviewSelection selection,
    int atMs,
  ) async {
    final PreviewMedia? visual = _visual;
    final ClipView? clip = selection.visualClip;
    if (visual == null || !visual.isReady || clip == null) {
      return;
    }
    if (_visualClipId != clip.id) {
      return; // 아직 새 클립으로 바뀌는 중
    }
    await _applyPosition(
      visual,
      sourceTimeFor(clip, atMs),
      fresh: _freshVisual,
      onSeekIssued: (int target) {
        // 시크 직후 플랫폼이 0을 보고해도 플레이헤드가 튀지 않게 한다.
        _visualHoldMs = target;
        _visualHoldDeadlineMs = _clockMs() + seekHoldTimeoutMs;
      },
    );
    _freshVisual = false;
    await _safeCall(() => visual.setVolume(selection.volume));
    await _safeCall(() => visual.setSpeed(clip.speed));
    if (_playing) {
      if (!_visualStarted) {
        _visualStarted = true;
        await _safeCall(visual.play);
      }
    } else if (_visualStarted) {
      _visualStarted = false;
      await _safeCall(visual.pause);
    }
  }

  Future<void> _syncAudio(PreviewSelection selection, int atMs) async {
    final PreviewMedia? audio = _audio;
    final ClipView? clip = selection.audioClip;
    if (audio == null || !audio.isReady || clip == null) {
      return;
    }
    if (_audioClipId != clip.id) {
      return;
    }
    await _applyPosition(audio, sourceTimeFor(clip, atMs), fresh: _freshAudio);
    _freshAudio = false;
    await _safeCall(() => audio.setVolume(selection.audioVolume));
    await _safeCall(() => audio.setSpeed(clip.speed));
    if (_playing) {
      if (!_audioStarted) {
        _audioStarted = true;
        await _safeCall(audio.play);
      }
    } else if (_audioStarted) {
      _audioStarted = false;
      await _safeCall(audio.pause);
    }
  }

  /// 대상 클립이 바뀌었으면 플레이어를 새로 연다.
  Future<void> _reconcileVisual(PreviewSelection sel) async {
    final ClipView? clip = sel.visualClip;
    final String? rawPath = sel.visualPath;
    final String? path =
        (clip != null && clip.kind == 'video' && rawPath != null && rawPath.isNotEmpty)
        ? rawPath
        : null;

    if (path == null) {
      // 빈 구간·이미지 클립: 플레이어를 즉시 버리지 않고 일시정지해 둔다.
      // 같은 프로젝트 안에서 클립 끝을 지나 빈 구간에 들어갔다가 돌아오는 경우가
      // 흔한데, 매번 dispose/open 하면 그때마다 수백 ms 멈추고 화면이 깜빡인다.
      // 실제 정리는 다른 파일을 열거나 엔진이 dispose 될 때 한다.
      final PreviewMedia? media = _visual;
      if (media != null) {
        _visualStarted = false;
        _visualClipId = null;
        _freshVisual = true;
        _visualClock.reset();
        await _safeCall(media.pause);
      }
      _failedVisualPath = null;
      return;
    }
    if (_failedVisualPath != null && _failedVisualPath != path) {
      _failedVisualPath = null;
    }
    if (_visual != null && _visualPath == path) {
      if (clip!.id != _visualClipId) {
        // 같은 파일을 자른 다른 클립: 인점으로 다시 시크한다(허용되는 시크).
        _visualClipId = clip.id;
        _freshVisual = true;
        _visualStarted = false;
        _visualClock.reset();
      }
      return;
    }
    if (_openingVisual) {
      return; // 이미 여는 중(한 번에 하나만 연다)
    }
    if (_failedVisualPath == path) {
      return; // 이미 실패한 파일 — 같은 경로를 다시 시도하지 않는다
    }
    await _openVisual(path, clip!.id);
  }

  Future<void> _openVisual(String path, String clipId) async {
    // 미리 열어 둔 컨트롤러가 있으면 그대로 쓴다(전환 지연 최소화).
    Future<PreviewMedia?>? pending;
    if (_preloadPath == path) {
      pending = _preload;
      _preload = null;
      _preloadPath = null;
    }
    await _closeVisual();
    final int generation = _openGeneration;
    _openingVisual = true;
    notifyListeners();
    try {
      PreviewMedia? media;
      if (pending != null) {
        media = await pending;
      }
      media ??= await _factory.open(path, wantVideo: true);
      if (_disposed || generation != _openGeneration) {
        await _safeCall(media.dispose);
        return;
      }
      _visual = media;
      _visualPath = path;
      _visualClipId = clipId;
      _freshVisual = true;
      _visualStarted = false;
      _visualClock.reset();
      _error = null;
      _repaint.value++;
    } on Object catch (error) {
      if (generation == _openGeneration) {
        _error = _describe(error);
        _failedVisualPath = path;
        _visualPath = null;
        _visual = null;
      }
    } finally {
      if (generation == _openGeneration) {
        _openingVisual = false;
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
      _failedAudioPath = null;
      return;
    }
    if (_failedAudioPath != null && _failedAudioPath != path) {
      _failedAudioPath = null;
    }
    if (_audio != null && _audioPath == path) {
      if (clip.id != _audioClipId) {
        _audioClipId = clip.id;
        _freshAudio = true;
        _audioStarted = false;
        _audioClock.reset();
      }
      return;
    }
    if (_openingAudio) {
      return; // 이미 여는 중(한 번에 하나만 연다)
    }
    if (_failedAudioPath == path) {
      return;
    }
    await _closeAudio();
    _openingAudio = true;
    try {
      final PreviewMedia media = await _factory.open(path, wantVideo: false);
      if (_disposed) {
        await _safeCall(media.dispose);
        return;
      }
      _audio = media;
      _audioPath = path;
      _audioClipId = clip.id;
      _freshAudio = true;
      _audioStarted = false;
      _audioClock.reset();
      _repaint.value++;
    } on Object catch (error) {
      _error ??= _describe(error);
      _failedAudioPath = path;
      _audioPath = null;
    } finally {
      _openingAudio = false;
    }
  }

  /// 다음 클립을 미리 열어 두어, 경계에서 "여는 시간"만큼 멈추지 않게 한다.
  void _maybePreload(EditorState state, PreviewSelection sel, int atMs) {
    if (!_playing) {
      _dropPreload();
      return;
    }
    final ClipView? clip = sel.visualClip;
    if (clip == null || clip.kind != 'video') {
      _dropPreload();
      return;
    }
    if (clip.endOffsetMs - atMs > preloadLeadMs) {
      return; // 아직 여유가 있다.
    }
    final ClipView? next = _nextVisualClipInTrack(state, clip);
    if (next == null || next.kind != 'video' || next.sourcePath.trim().isEmpty) {
      _dropPreload();
      return;
    }
    if (next.sourcePath == clip.sourcePath) {
      // 같은 파일이면 지금 컨트롤러를 그대로 이어 쓰면 된다(새로 열 필요 없음).
      _dropPreload();
      return;
    }
    if (_preloadPath == next.sourcePath || _preloadFailedPath == next.sourcePath) {
      return;
    }
    _dropPreload();
    _preloadPath = next.sourcePath;
    _preload = _factory
        .open(next.sourcePath, wantVideo: true)
        .then<PreviewMedia?>((PreviewMedia media) => media)
        .catchError((Object _) {
          _preloadFailedPath = next.sourcePath;
          if (_preloadPath == next.sourcePath) {
            _preloadPath = null;
            _preload = null;
          }
          return null;
        });
  }

  ClipView? _nextVisualClipInTrack(EditorState state, ClipView current) {
    for (final TrackView track in state.tracks) {
      if (track.kind == 'audio' || track.hidden) {
        continue;
      }
      final int index = track.clips.indexWhere((ClipView c) => c.id == current.id);
      if (index < 0) {
        continue;
      }
      if (index + 1 < track.clips.length) {
        return track.clips[index + 1];
      }
      return null;
    }
    return null;
  }

  /// 미리 열어 둔 클립을 버린다(쓰지 않으면 자원을 돌려준다).
  void _dropPreload() {
    final Future<PreviewMedia?>? pending = _preload;
    _preload = null;
    _preloadPath = null;
    if (pending == null) {
      return;
    }
    unawaited(
      pending
          .then<void>((PreviewMedia? media) async {
            if (media != null) {
              await _safeCall(media.dispose);
            }
          })
          .catchError((Object _) {}),
    );
  }

  /// 플레이어 위치를 목표 소스 시각에 맞춘다.
  ///
  /// 재생 중 같은 클립 안에서는 **시크하지 않는다**(시크는 키프레임 재탐색으로
  /// 재생이 끊긴다). [fresh]일 때(새로 열었거나 다른 클립으로 넘어왔을 때)와
  /// 일시정지 상태에서 큰 오차가 있을 때만 시크한다.
  Future<void> _applyPosition(
    PreviewMedia media,
    int targetMs, {
    required bool fresh,
    void Function(int targetMs)? onSeekIssued,
  }) async {
    final int current = media.positionMs;
    final int limit = fresh
        ? freshSeekSlackMs
        : (_playing ? playingSlackMs : scrubSeekThresholdMs);
    if ((current - targetMs).abs() <= limit) {
      return;
    }
    if (_seekInFlight) {
      _pendingSeekMs = targetMs;
      return;
    }
    _seekInFlight = true;
    try {
      onSeekIssued?.call(targetMs);
      await media.seekTo(targetMs);
    } on Object catch (error) {
      _error ??= _describe(error);
    } finally {
      _seekInFlight = false;
      final int pending = _pendingSeekMs;
      _pendingSeekMs = -1;
      if (pending >= 0 && (pending - targetMs).abs() > scrubSeekThresholdMs) {
        await _applyPosition(media, pending, fresh: true, onSeekIssued: onSeekIssued);
      }
    }
  }

  Future<void> _closeVisual() async {
    final PreviewMedia? media = _visual;
    _visual = null;
    _visualPath = null;
    _visualClipId = null;
    _visualStarted = false;
    _freshVisual = false;
    _openGeneration++;
    _visualClock.reset();
    _repaint.value++;
    if (media != null) {
      await _safeCall(media.dispose);
    }
  }

  Future<void> _closeAudio() async {
    final PreviewMedia? media = _audio;
    _audio = null;
    _audioPath = null;
    _audioClipId = null;
    _audioStarted = false;
    _freshAudio = false;
    _audioClock.reset();
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
    if (_disposed) {
      return;
    }
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    _controller.removeListener(_onControllerChanged);
    _dropPreload();
    final PreviewMedia? visual = _visual;
    final PreviewMedia? audio = _audio;
    _visual = null;
    _audio = null;
    unawaited(visual?.dispose() ?? Future<void>.value());
    unawaited(audio?.dispose() ?? Future<void>.value());
    _repaint.dispose();
    _position.dispose();
    super.dispose();
  }
}

/// 테스트용 가짜 미디어. 열린 경로/시크/재생 호출을 기록한다.
///
/// [clockMs]를 주면 실제 플레이어처럼 재생 중 위치가 흐른다(재생 시계 검증용).
class FakePreviewMedia implements PreviewMedia {
  FakePreviewMedia(
    this.path, {
    this.video = true,
    this.aspect = 9 / 16,
    this.clockMs,
  });

  @override
  final String path;

  final bool video;
  final double aspect;
  final int Function()? clockMs;

  bool ready = true;
  bool playing = false;
  int seekCount = 0;
  int playCount = 0;
  int pauseCount = 0;
  int volumeCalls = 0;
  int speedCalls = 0;
  int positionReads = 0;
  double volume = 1;
  double speed = 1;
  bool disposed = false;

  int _base = 0;
  int _playedFrom = 0;

  @override
  bool get isReady => ready;

  @override
  int get positionMs {
    positionReads++;
    if (!playing) {
      return _base;
    }
    final int now = clockMs?.call() ?? _playedFrom;
    final int advanced = _base + (now - _playedFrom);
    return advanced < _base ? _base : advanced;
  }

  @override
  double get aspectRatio => aspect;

  @override
  bool get hasVideo => video;

  @override
  Future<void> play() async {
    playCount++;
    if (playing) {
      return;
    }
    _playedFrom = clockMs?.call() ?? 0;
    playing = true;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    if (playing) {
      _base = positionMs;
    }
    playing = false;
  }

  @override
  Future<void> seekTo(int sourceMs) async {
    _base = sourceMs < 0 ? 0 : sourceMs;
    _playedFrom = clockMs?.call() ?? 0;
    seekCount++;
  }

  @override
  Future<void> setVolume(double value) async {
    volumeCalls++;
    volume = value;
  }

  @override
  Future<void> setSpeed(double value) async {
    speedCalls++;
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
  FakePreviewMediaFactory({this.fail = false, this.clockMs});

  final bool fail;
  final int Function()? clockMs;
  final List<String> opened = <String>[];
  final Map<String, FakePreviewMedia> media = <String, FakePreviewMedia>{};

  @override
  Future<PreviewMedia> open(String path, {required bool wantVideo}) async {
    opened.add(path);
    if (fail) {
      throw const PreviewMediaException('테스트: 재생할 수 없음');
    }
    final FakePreviewMedia item = FakePreviewMedia(
      path,
      video: wantVideo,
      clockMs: clockMs,
    );
    media[path] = item;
    return item;
  }
}
