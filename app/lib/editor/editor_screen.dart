import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../bridge_api.dart';
import '../models.dart';
import '../theme.dart';
import 'inspector_panel.dart';
import 'preview_panel.dart';
import 'timeline_view.dart';

/// 편집 화면 전체.
///
/// 레이아웃: [프리뷰] → [트랜스포트] → [타임라인] → (선택 시) [인스펙터]
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, this.controller});

  /// 테스트에서 가짜 브리지를 끼울 때 쓴다. 없으면 실제 Rust 코어를 쓴다.
  final EditorController? controller;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final EditorController _controller =
      widget.controller ?? EditorController();
  Timer? _playTimer;
  bool _playing = false;

  bool get _ownsController => widget.controller == null;

  @override
  void initState() {
    super.initState();
    // 위젯 첫 프레임 뒤에 코어를 깨운다(초기 레이아웃 지연 방지).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_controller.bootstrap());
    });
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- playback

  void _togglePlay() {
    if (_playing) {
      _stopPlayback();
      return;
    }
    if (_controller.durationMs <= 0) {
      return;
    }
    setState(() => _playing = true);
    _playTimer = Timer.periodic(const Duration(milliseconds: 33), (
      Timer timer,
    ) {
      final int next = _controller.playheadMs + 33;
      if (next >= _controller.durationMs) {
        _controller.setPlayhead(_controller.durationMs);
        _stopPlayback();
        return;
      }
      _controller.setPlayhead(next);
    });
  }

  void _stopPlayback() {
    _playTimer?.cancel();
    _playTimer = null;
    if (mounted) {
      setState(() => _playing = false);
    }
  }

  // ------------------------------------------------------------------ actions

  Future<void> _saveProject() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final String stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      final String path = '${directory.path}/muud-edits-$stamp.muudproj';
      await _controller.saveProject(path);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('저장하지 못했습니다: $error')));
    }
  }

  /// 새 프로젝트. 저장하지 않은 편집이 있으면 먼저 확인한다.
  Future<void> _newProject() async {
    final bool dirty = _controller.state?.summary.dirty ?? false;
    if (dirty) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          backgroundColor: EditorPalette.surface,
          title: const Text('새 프로젝트'),
          content: const Text('저장하지 않은 편집이 있습니다. 버리고 새로 시작할까요?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('새로 시작'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
    }
    await _controller.newProject();
  }

  /// 파일 선택 → 프로브 → 클립 추가. 파일 선택기를 쓸 수 없으면 수동 입력。
  Future<void> _addMedia() async {
    PlatformFile? picked;
    try {
      // file_picker 13: FilePicker.pickFile()는 정적 메서드이고 PlatformFile?을 돌려준다.
      picked = await FilePicker.pickFile(type: FileType.media);
    } catch (_) {
      // 데스크톱/샌드박스에서 플러그인이 없을 수 있다.
      if (mounted) {
        await _addMediaManually();
      }
      return;
    }
    if (picked == null) {
      return; // 사용자가 취소
    }
    final String? path = picked.path;
    if (path == null || path.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('파일 경로를 읽지 못했습니다')));
      }
      return;
    }
    await _controller.addMediaFile(path);
  }

  /// 파일 선택기를 쓸 수 없을 때: 경로와 길이를 직접 입력.
  Future<void> _addMediaManually() async {
    final TextEditingController pathController = TextEditingController(
      text: '/media/clip.mp4',
    );
    final TextEditingController lengthController = TextEditingController(
      text: '5',
    );
    String kind = 'video';

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              backgroundColor: EditorPalette.surface,
              title: const Text('미디어 추가'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: pathController,
                    decoration: const InputDecoration(labelText: '파일 경로'),
                  ),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: lengthController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: '길이(초)'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SegmentedButton<String>(
                        segments: const <ButtonSegment<String>>[
                          ButtonSegment<String>(
                            value: 'video',
                            label: Text('영상'),
                          ),
                          ButtonSegment<String>(
                            value: 'audio',
                            label: Text('오디오'),
                          ),
                        ],
                        selected: <String>{kind},
                        onSelectionChanged: (Set<String> value) {
                          setDialogState(() => kind = value.first);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '※ 네이티브 미디어 엔진이 연결되어 있으면 길이·해상도는 자동으로 읽습니다.\n'
                    '여기서는 엔진이 없을 때를 위한 수동 입력만 받습니다.',
                    style: TextStyle(
                      color: EditorPalette.textMuted,
                      fontSize: 10,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('추가하기'),
                ),
              ],
            );
          },
        );
      },
    );

    final String path = pathController.text.trim();
    final int seconds = int.tryParse(lengthController.text.trim()) ?? 5;
    pathController.dispose();
    lengthController.dispose();

    if (confirmed == true && path.isNotEmpty) {
      await _controller.addMediaClip(
        sourcePath: path,
        kind: kind,
        startMs: 0,
        endMs: (seconds < 1 ? 1 : (seconds > 600 ? 600 : seconds)) * 1000,
      );
    }
  }

  Future<void> _addText() async {
    final String? content = await _promptText(
      title: '텍스트 추가',
      hint: '화면에 표시할 문구',
    );
    if (content != null && content.isNotEmpty) {
      await _controller.addTextOverlay(content);
    }
  }

  Future<void> _addSubtitle() async {
    final String? content = await _promptText(
      title: '자막 추가',
      hint: '재생 헤드에서 2초',
    );
    if (content != null && content.isNotEmpty) {
      await _controller.addSubtitleHere(content);
    }
  }

  Future<String?> _promptText({
    required String title,
    required String hint,
  }) async {
    final TextEditingController controller = TextEditingController();
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: EditorPalette.surface,
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (String value) => Navigator.of(context).pop(value),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('확인'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  void _openExportSheet() {
    unawaited(_controller.prepareExport());
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: EditorPalette.surface,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return _ExportSheet(controller: _controller);
      },
    );
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, Widget? child) {
        final EditorState? state = _controller.state;
        final ProjectSummary? summary = state?.summary;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: EditorPalette.surface,
            titleSpacing: 12,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      summary?.name ?? 'muud-edits',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (summary != null && summary.dirty) ...<Widget>[
                      const SizedBox(width: 6),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: EditorPalette.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  summary == null
                      ? '코어 연결 중…'
                      : '${summary.durationLabel} · ${summary.clipCount}클립 · 자막 ${summary.subtitleCount}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: EditorPalette.textMuted,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              if (_controller.busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              IconButton(
                tooltip: '새 프로젝트',
                onPressed: _controller.ready ? _newProject : null,
                icon: const Icon(Icons.add_box_outlined),
              ),
              IconButton(
                tooltip: summary?.undoLabel == null
                    ? '되돌리기'
                    : '되돌리기 (${summary?.undoLabel})',
                onPressed: (summary?.canUndo ?? false)
                    ? _controller.undo
                    : null,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: '다시 적용',
                onPressed: (summary?.canRedo ?? false)
                    ? _controller.redo
                    : null,
                icon: const Icon(Icons.redo),
              ),
              IconButton(
                tooltip: '저장',
                onPressed: _controller.ready ? _saveProject : null,
                icon: const Icon(Icons.save_outlined),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  onPressed: _controller.ready ? _openExportSheet : null,
                  icon: const Icon(Icons.ios_share, size: 16),
                  label: const Text('내보내기'),
                ),
              ),
            ],
          ),
          body: Column(
            children: <Widget>[
              if (_controller.error != null)
                _MessageBar(
                  message: _controller.error!,
                  isError: true,
                  onClose: _controller.clearMessages,
                  retryLabel: _controller.ready ? null : '다시 시도',
                  onRetry: _controller.ready
                      ? null
                      : () => unawaited(_controller.bootstrap()),
                ),
              if (_controller.notice != null)
                _MessageBar(
                  message: _controller.notice!,
                  isError: false,
                  onClose: _controller.clearMessages,
                ),
              Expanded(
                child:
                    (summary != null &&
                        summary.clipCount == 0 &&
                        summary.subtitleCount == 0)
                    ? _StartView(
                        onAddMedia: _controller.ready ? _addMedia : null,
                        onAddText: _controller.ready ? _addText : null,
                        onAddSubtitle: _controller.ready ? _addSubtitle : null,
                        onExport: _controller.ready ? _openExportSheet : null,
                      )
                    : PreviewPanel(controller: _controller),
              ),
              _buildTransport(summary),
              SizedBox(
                height: 206,
                child: TimelineView(controller: _controller),
              ),
              if (_controller.selected != null)
                Container(
                  height: 190,
                  decoration: const BoxDecoration(
                    color: EditorPalette.surface,
                    border: Border(
                      top: BorderSide(color: EditorPalette.outline),
                    ),
                  ),
                  child: InspectorPanel(controller: _controller),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTransport(ProjectSummary? summary) {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: EditorPalette.surface,
        border: Border(top: BorderSide(color: EditorPalette.outline)),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '한 프레임 뒤로',
            onPressed: () => _controller.stepFrames(-1),
            icon: const Icon(Icons.skip_previous, size: 20),
          ),
          IconButton(
            tooltip: _playing ? '일시정지' : '재생',
            onPressed: _controller.ready ? _togglePlay : null,
            icon: Icon(
              _playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
              size: 30,
              color: EditorPalette.accent,
            ),
          ),
          IconButton(
            tooltip: '한 프레임 앞으로',
            onPressed: () => _controller.stepFrames(1),
            icon: const Icon(Icons.skip_next, size: 20),
          ),
          const SizedBox(width: 4),
          Text(
            formatTimecode(_controller.playheadMs),
            style: const TextStyle(
              fontSize: 11,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '재생 헤드에서 분할',
            onPressed: _controller.ready ? _controller.splitAtPlayhead : null,
            icon: const Icon(Icons.content_cut, size: 20),
          ),
          IconButton(
            tooltip: '미디어 추가',
            onPressed: _controller.ready ? _addMedia : null,
            icon: const Icon(Icons.video_call_outlined, size: 20),
          ),
          IconButton(
            tooltip: '텍스트 추가',
            onPressed: _controller.ready ? _addText : null,
            icon: const Icon(Icons.title, size: 20),
          ),
          IconButton(
            tooltip: '자막 추가',
            onPressed: _controller.ready ? _addSubtitle : null,
            icon: const Icon(Icons.subtitles_outlined, size: 20),
          ),
        ],
      ),
    );
  }
}

class _MessageBar extends StatelessWidget {
  const _MessageBar({
    required this.message,
    required this.isError,
    required this.onClose,
    this.retryLabel,
    this.onRetry,
  });

  final String message;
  final bool isError;
  final VoidCallback onClose;

  /// 오류 배너에 붙는 복구 버튼(예: 코어 재시도). 없으면 표시하지 않는다.
  final String? retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final Color color = isError
        ? EditorPalette.playhead
        : EditorPalette.audioTrack;
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.14),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 11, height: 1.35),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: color,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                retryLabel ?? '다시 시도',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          IconButton(
            onPressed: onClose,
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// 내보내기 계획 시트.
class _ExportSheet extends StatelessWidget {
  const _ExportSheet({required this.controller});

  final EditorController controller;

  static const List<String> _platforms = <String>[
    'macos',
    'windows',
    'android',
    'ios',
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        final ExportPlan? plan = controller.lastPlan;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '내보내기 계획',
                  style: TextStyle(
                    color: EditorPalette.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '워터마크 없음 · 하드웨어 인코더 우선',
                  style: TextStyle(
                    color: EditorPalette.textMuted,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    for (final String platform in _platforms)
                      ChoiceChip(
                        label: Text(platform),
                        selected: controller.exportPlatform == platform,
                        onSelected: (bool selected) {
                          if (!selected) {
                            return;
                          }
                          controller.setExportPlatform(platform);
                          unawaited(controller.prepareExport());
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                if (plan == null)
                  const Text(
                    '계획을 계산하는 중…',
                    style: TextStyle(
                      color: EditorPalette.textMuted,
                      fontSize: 11,
                    ),
                  )
                else ...<Widget>[
                  Text(
                    plan.summaryLabel,
                    style: const TextStyle(
                      color: EditorPalette.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final String note in plan.notes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '· $note',
                        style: const TextStyle(
                          color: EditorPalette.textMuted,
                          fontSize: 10,
                          height: 1.35,
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  if (controller.lastRenderPlan != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '렌더 그래프 · ${controller.lastRenderPlan!.frameCount}프레임 · '
                        '영상 ${controller.lastRenderPlan!.segmentCount} / 오디오 ${controller.lastRenderPlan!.audioSegmentCount} / '
                        '자막 ${controller.lastRenderPlan!.subtitleCount} · ${controller.lastRenderPlan!.digest}',
                        style: const TextStyle(
                          color: EditorPalette.textMuted,
                          fontSize: 10,
                          height: 1.35,
                        ),
                      ),
                    ),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 110),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: EditorPalette.background,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: EditorPalette.outline),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        plan.command,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: EditorPalette.textMuted,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                _buildProgress(context),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    OutlinedButton(
                      onPressed: () => unawaited(controller.prepareExport()),
                      child: const Text('다시 계산'),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '플랫폼: ${controller.exportPlatform}',
                      style: const TextStyle(
                        color: EditorPalette.textMuted,
                        fontSize: 10,
                      ),
                    ),
                    const Spacer(),
                    if (controller.exportProgress?.isRunning ?? false)
                      OutlinedButton.icon(
                        onPressed:
                            (controller.exportProgress?.canCancel ?? false)
                            ? () => unawaited(controller.cancelExport())
                            : null,
                        icon: const Icon(Icons.close, size: 16),
                        label: const Text('취소'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: plan == null
                            ? null
                            : () => unawaited(controller.startExport()),
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('내보내기 시작'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 진행률 바 + 상태 문구 + 결과 경로.
  Widget _buildProgress(BuildContext context) {
    final ExportProgressView? progress = controller.exportProgress;
    if (progress == null) {
      if (controller.mediaEngineMissing) {
        return const Text(
          '네이티브 미디어 엔진이 연결되지 않았습니다. docs/LOCAL_SETUP.md의 '
          '"네이티브 미디어 레이어 연결"을 참고하세요.',
          style: TextStyle(
            color: EditorPalette.audioTrack,
            fontSize: 10,
            height: 1.4,
          ),
        );
      }
      return const SizedBox.shrink();
    }
    final Color color = progress.state == 'failed'
        ? EditorPalette.playhead
        : (progress.state == 'completed'
              ? EditorPalette.audioTrack
              : EditorPalette.accent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '${progress.stateLabel} · ${progress.percent.toStringAsFixed(1)}%'
              ' (${progress.completedFrames}/${progress.totalFrames})',
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (progress.etaLabel.isNotEmpty)
              Text(
                progress.etaLabel,
                style: const TextStyle(
                  color: EditorPalette.textMuted,
                  fontSize: 10,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress.fraction.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: EditorPalette.background,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        if (progress.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              progress.error!,
              style: const TextStyle(
                color: EditorPalette.playhead,
                fontSize: 10,
                height: 1.35,
              ),
            ),
          ),
        if (progress.state == 'completed' &&
            controller.exportOutputPath != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(
              controller.exportOutputPath!,
              style: const TextStyle(
                color: EditorPalette.textMuted,
                fontSize: 10,
              ),
            ),
          ),
      ],
    );
  }
}

/// 빈 프로젝트에서 처음 켠 사용자가 바로 시작할 수 있게 하는 안내 화면.
///
/// 프리뷰 자리를 대신 채우며, 첫 화면에서 눈에 띄는 단일 행동(영상 추가)을 준다.
class _StartView extends StatelessWidget {
  const _StartView({
    required this.onAddMedia,
    required this.onAddText,
    required this.onAddSubtitle,
    required this.onExport,
  });

  final VoidCallback? onAddMedia;
  final VoidCallback? onAddText;
  final VoidCallback? onAddSubtitle;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: EditorPalette.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.movie_filter_outlined,
                  color: EditorPalette.accent,
                  size: 30,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '새 프로젝트가 준비됐어요',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: EditorPalette.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '영상을 고르면 길이·해상도를 읽어 타임라인에 놓습니다.\n'
                '자르고, 자막을 얹고, 워터마크 없이 내보내세요.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: EditorPalette.textMuted,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onAddMedia,
                icon: const Icon(Icons.video_call_outlined, size: 18),
                label: const Text('영상 · 사진 추가'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onAddText,
                      icon: const Icon(Icons.title, size: 16),
                      label: const Text('텍스트'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onAddSubtitle,
                      icon: const Icon(Icons.subtitles_outlined, size: 16),
                      label: const Text('자막'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onExport,
                      icon: const Icon(Icons.ios_share, size: 16),
                      label: const Text('내보내기'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const _StepHints(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 1-2-3 안내(처음 쓰는 사람이 다음 순서를 알 수 있게).
class _StepHints extends StatelessWidget {
  const _StepHints();

  static const List<(String, String)> _steps = <(String, String)>[
    ('1', '미디어 추가 — 갤러리에서 영상이나 사진을 고릅니다'),
    ('2', '타임라인 편집 — 재생 헤드에서 자르고, 텍스트·자막을 얹습니다'),
    ('3', '내보내기 — 기기 하드웨어 인코더로 저장합니다'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (String number, String text) in _steps)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: EditorPalette.surfaceHigh,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    number,
                    style: const TextStyle(
                      color: EditorPalette.textMuted,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: EditorPalette.textMuted,
                      fontSize: 10,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
