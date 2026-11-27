import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../bridge_api.dart';
import '../models.dart';
import '../theme.dart';
import 'editor_section.dart';
import 'inspector_panel.dart';
import 'mobile_toolbar.dart';
import 'preview_engine.dart';
import 'preview_panel.dart';
import 'timeline_view.dart';
import 'workspace.dart';

/// 상단 바 키(레이아웃 계약 테스트용).
const Key editorTopBarKey = ValueKey<String>('editor-top-bar');
const Key editorTransportKey = ValueKey<String>('editor-transport');
const Key previewFullscreenKey = ValueKey<String>('editor-preview-fullscreen');
const Key projectNameKey = ValueKey<String>('editor-project-name');
const Key qualityBadgeKey = ValueKey<String>('editor-quality-badge');

/// 편집 화면 전체.
///
/// Astryx 의 outside-in 구조를 따른다:
///
/// ```
/// 상단 바(프로젝트 이름 · 실행 취소/다시 실행 · 내보내기 하나의 primary)
/// ├─ [미리보기 | 인스펙터]   ← 넓은 화면. 경계는 드래그로 리사이즈
/// ├─ 트랜스포트(재생 · 편집 도구)
/// └─ 타임라인                ← 높이 조절 핸들
/// ```
///
/// 좁은 화면(<768px)에서는 인스펙터가 하단 BottomSheet 로 스왑되고,
/// 툴바는 48dp 터치 타깃을 확보한다([EditorWorkspace]).
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, this.controller, this.previewEngine});

  /// 테스트에서 가짜 브리지를 끼울 때 쓴다. 없으면 실제 Rust 코어를 쓴다.
  final EditorController? controller;

  /// 테스트에서 가짜 플레이어를 끼울 때 쓴다. 없으면 실제 플러그인을 쓴다.
  final PreviewEngine? previewEngine;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final EditorController _controller =
      widget.controller ?? EditorController();
  late final PreviewEngine _engine =
      widget.previewEngine ?? PreviewEngine(controller: _controller);

  bool get _ownsController => widget.controller == null;

  bool get _playing => _engine.isPlaying;

  /// 모바일 전체화면 프리뷰(상단 바·타임라인·툴바를 숨긴다).
  bool _previewFullscreen = false;

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
    _engine.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- playback

  void _togglePlay() {
    if (_controller.durationMs <= 0) {
      return;
    }
    _engine.togglePlay();
  }

  /// 분할·자막·프레임 이동처럼 [EditorController]의 플레이헤드를 읽는 동작 전에
  /// 재생을 멈추고 지금 위치를 옮겨 적는다.
  void _pauseForEdit() => _engine.pause();

  // ------------------------------------------------------------------ actions

  Future<void> _saveProject() async {
    _pauseForEdit();
    try {
      final directory = await getApplicationDocumentsDirectory();
      final String stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      final String path = '${directory.path}/muud-edits-$stamp.muudproj';
      await _controller.saveProject(path);
      if (!mounted) {
        return;
      }
      final String where = _controller.lastSavedProjectDisplay ?? path;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('프로젝트를 저장했습니다\n$where'),
          action: _controller.error == null
              ? SnackBarAction(
                  label: '공유',
                  onPressed: () => unawaited(_controller.saveShare(path)),
                )
              : null,
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('저장하지 못했습니다: $error')));
    }
  }

  /// 저장한 프로젝트 파일(.muudproj)을 열어 편집을 이어 간다.
  Future<void> _openProject() async {
    _pauseForEdit();
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: '프로젝트 열기',
        type: FileType.custom,
        allowedExtensions: const <String>['muudproj', 'json'],
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('파일 선택기를 열지 못했습니다: $error')),
      );
      return;
    }
    if (picked == null) {
      return;
    }
    final String? path = picked.path;
    if (path == null || path.isEmpty) {
      return;
    }
    final bool loaded = await _controller.loadProject(path);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          loaded
              ? '프로젝트를 열었습니다'
              : '프로젝트를 열지 못했습니다: ${_controller.error ?? ''}',
        ),
      ),
    );
  }

  /// 새 프로젝트. 저장하지 않은 편집이 있으면 먼저 확인한다.
  Future<void> _newProject() async {
    _pauseForEdit();
    final bool dirty = _controller.state?.summary.dirty ?? false;
    if (dirty) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
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

  /// 파일 선택 → 프로브 → 클립 추가. 파일 선택기를 쓸 수 없으면 수동 입력.
  Future<void> _addMedia() async {
    await _pickAndAddMedia();
  }

  /// 오디오 파일 추가(오디오 트랙).
  ///
  /// `FileType.media` 는 iOS 에서 사진/영상만 보여 주므로(오디오 선택 불가),
  /// 오디오는 `FileType.audio` 로 따로 연다. 고른 파일은 프로브가 종류를 판단해
  /// 오디오 트랙에 놓인다.
  Future<void> _addAudio() async {
    await _pickAndAddMedia(audioOnly: true);
  }

  /// 오버레이 트랙에 사진/영상을 얹는다(프로젝트의 첫 오버레이 트랙).
  Future<void> _addOverlayMedia() async {
    final TrackView? track = _controller.firstOverlayTrack;
    if (track == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('오버레이 트랙이 없습니다')));
      return;
    }
    await _pickAndAddMedia(trackId: track.id);
  }

  Future<void> _pickAndAddMedia({
    String? trackId,
    bool audioOnly = false,
  }) async {
    _pauseForEdit();
    PlatformFile? picked;
    try {
      // file_picker 13: FilePicker.pickFile()는 정적 메서드이고 PlatformFile?을 돌려준다.
      picked = await FilePicker.pickFile(
        type: audioOnly ? FileType.audio : FileType.media,
      );
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
    await _controller.addMediaFile(path, trackId: trackId);
  }

  /// 상단 바에서 프로젝트 이름을 탭하면 이름을 고친다.
  Future<void> _renameProject() async {
    final String current = _controller.state?.summary.name ?? '새 프로젝트';
    final String? next = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _RenameProjectDialog(initial: current),
    );
    if (next == null) {
      return;
    }
    await _controller.renameProject(next);
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
              title: const Text('미디어 추가'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: pathController,
                    decoration: const InputDecoration(labelText: '파일 경로'),
                  ),
                  const SizedBox(height: EditorSpacing.sm),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: lengthController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: '길이(초)'),
                        ),
                      ),
                      const SizedBox(width: EditorSpacing.md),
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
                  const SizedBox(height: EditorSpacing.sm),
                  const Text(
                    '※ 네이티브 미디어 엔진이 연결되어 있으면 길이·해상도는 자동으로 읽습니다.\n'
                    '여기서는 엔진이 없을 때를 위한 수동 입력만 받습니다.',
                    style: EditorText.caption,
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
    _pauseForEdit();
    final String? content = await _promptText(
      title: '텍스트 추가',
      hint: '화면에 표시할 문구',
    );
    if (content != null && content.isNotEmpty) {
      await _controller.addTextOverlay(content);
    }
  }

  Future<void> _addSubtitle() async {
    _pauseForEdit();
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

  /// 자막을 목록에서 골라 문구/구간을 고치거나 지운다.
  Future<void> _openSubtitlesSheet() async {
    _pauseForEdit();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: EditorSurfaces.panel,
      isScrollControlled: true,
      builder: (BuildContext context) => _SubtitlesSheet(controller: _controller),
    );
  }

  void _openExportSheet() {
    _pauseForEdit();
    unawaited(_controller.prepareExport());
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: EditorSurfaces.panel,
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
      listenable: Listenable.merge(<Listenable>[_controller, _engine]),
      builder: (BuildContext context, Widget? child) {
        final EditorState? state = _controller.state;
        final ProjectSummary? summary = state?.summary;
        final bool compact =
            MediaQuery.sizeOf(context).width < EditorBreakpoints.compact;
        final bool emptyProject =
            summary != null &&
            summary.clipCount == 0 &&
            summary.subtitleCount == 0;

        if (compact && _previewFullscreen) {
          return _buildFullscreenPreview(context, state);
        }

        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                compact
                    ? _buildMobileTopBar(context, summary)
                    : _buildTopBar(context, summary),
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
                  child: EditorWorkspace(
                    controller: _controller,
                    preview: emptyProject
                        ? _StartView(
                            onAddMedia: _controller.ready ? _addMedia : null,
                            onAddText: _controller.ready ? _addText : null,
                            onAddSubtitle: _controller.ready
                                ? _addSubtitle
                                : null,
                            onExport: _controller.ready ? _openExportSheet : null,
                          )
                        : PreviewPanel(controller: _controller, engine: _engine),
                    transport: compact
                        ? _buildMobileTransport(context)
                        : _buildTransport(context, compact),
                    timeline: TimelineView(
                      controller: _controller,
                      playhead: _engine.position,
                      onScrubStart: _engine.pause,
                      onAddClip: _controller.ready ? _addMedia : null,
                    ),
                    compactFooter: compact
                        ? MobileToolbar(
                            controller: _controller,
                            onAddMedia: _addMedia,
                            onAddAudio: state == null
                                ? () {}
                                : _addAudio,
                            onAddText: _addText,
                            onAddOverlay: state == null
                                ? () {}
                                : _addOverlayMedia,
                            onAddSubtitle: _openSubtitlesSheet,
                          )
                        : null,
                    inspectorBuilder: (VoidCallback onClose) => InspectorPanel(
                      controller: _controller,
                      onClose: onClose,
                      closeTooltip: compact ? '닫기' : '선택 해제',
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 전체화면 프리뷰(모바일). 영상 판단을 방해하지 않도록 UI 를 모두 감춘다.
  Widget _buildFullscreenPreview(BuildContext context, EditorState? state) {
    return Scaffold(
      key: previewFullscreenKey,
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _previewFullscreen = false),
                child: state == null
                    ? const SizedBox.shrink()
                    : PreviewPanel(controller: _controller, engine: _engine),
              ),
            ),
            Positioned(
              top: EditorSpacing.sm,
              right: EditorSpacing.sm,
              child: IconButton.filledTonal(
                tooltip: '전체화면 닫기',
                onPressed: () => setState(() => _previewFullscreen = false),
                icon: const Icon(Icons.fullscreen_exit),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 모바일 상단 바

  /// Meta Edits 스타일 모바일 상단 바.
  ///
  /// 왼쪽: 프로젝트 메뉴(새로 만들기·열기·저장).
  /// 가운데: 프로젝트 이름(탭하면 이름 변경) + 미저장 점.
  /// 오른쪽: 해상도 배지(`1080p`) + 보라색 내보내기 버튼 — 화면에서 유일한 primary.
  Widget _buildMobileTopBar(BuildContext context, ProjectSummary? summary) {
    final String name = summary?.name ?? 'muud-edits';
    final bool dirty = summary?.dirty ?? false;
    return Container(
      key: editorTopBarKey,
      height: 56,
      padding: const EdgeInsets.only(
        left: EditorSpacing.xs,
        right: EditorSpacing.sm,
      ),
      decoration: const BoxDecoration(
        color: EditorSurfaces.panel,
        border: Border(
          bottom: BorderSide(
            color: EditorSurfaces.divider,
            width: EditorStroke.hairline,
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          _ProjectMenu(
            density: EditorDensity.touch,
            ready: _controller.ready,
            onNew: _newProject,
            onOpen: _openProject,
            onSave: _saveProject,
          ),
          Expanded(
            child: InkWell(
              key: projectNameKey,
              borderRadius: EditorRadius.smAll,
              onTap: _controller.ready ? _renameProject : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: EditorSpacing.xs,
                  vertical: EditorSpacing.sm,
                ),
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: EditorText.lead,
                      ),
                    ),
                    if (dirty) ...<Widget>[
                      const SizedBox(width: EditorSpacing.sm),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: EditorSurfaces.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Container(
            key: qualityBadgeKey,
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: EditorSurfaces.raised,
              borderRadius: EditorRadius.smAll,
              border: Border.all(
                color: EditorSurfaces.divider,
                width: EditorStroke.hairline,
              ),
            ),
            child: Text(
              _controller.qualityLabel,
              style: EditorText.numeric.copyWith(fontSize: 10),
            ),
          ),
          const SizedBox(width: EditorSpacing.sm),
          FilledButton.icon(
            onPressed: _controller.ready ? _openExportSheet : null,
            icon: const Icon(Icons.ios_share, size: 15),
            label: const Text('내보내기'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: EditorSpacing.md),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ top bar

  /// 상단 바: 프로젝트 이름 하나를 lead 로, 실행 취소/다시 실행, 그리고
  /// **단 하나의 primary action**(내보내기)만 강조한다. 새 프로젝트·열기·저장은
  /// 프로젝트 메뉴로 내려 시선을 뺏지 않게 한다.
  Widget _buildTopBar(BuildContext context, ProjectSummary? summary) {
    final double width = MediaQuery.sizeOf(context).width;
    final bool compact = width < EditorBreakpoints.compact;
    final EditorDensity density = EditorDensity.forWidth(width);

    final List<Widget> actions = <Widget>[
      if (_controller.busy)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: EditorSpacing.sm),
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      _BarIconButton(
        tooltip: summary?.undoLabel == null
            ? '되돌리기'
            : '되돌리기 (${summary?.undoLabel})',
        icon: Icons.undo,
        density: density,
        onPressed: (summary?.canUndo ?? false) ? _controller.undo : null,
      ),
      _BarIconButton(
        tooltip: '다시 적용',
        icon: Icons.redo,
        density: density,
        onPressed: (summary?.canRedo ?? false) ? _controller.redo : null,
      ),
      _ProjectMenu(
        density: density,
        ready: _controller.ready,
        onNew: _newProject,
        onOpen: _openProject,
        onSave: _saveProject,
      ),
      const SizedBox(width: EditorSpacing.sm),
      if (compact)
        IconButton.filled(
          tooltip: '내보내기',
          onPressed: _controller.ready ? _openExportSheet : null,
          constraints: BoxConstraints.tightFor(
            width: density.minTarget,
            height: density.minTarget,
          ),
          icon: const Icon(Icons.ios_share, size: 20),
        )
      else
        FilledButton.icon(
          onPressed: _controller.ready ? _openExportSheet : null,
          icon: const Icon(Icons.ios_share, size: 16),
          label: const Text('내보내기'),
        ),
    ];

    final String meta = summary == null
        ? '코어 연결 중…'
        : '${summary.durationLabel} · ${summary.clipCount}클립 · '
              '자막 ${summary.subtitleCount}';

    return Container(
      key: editorTopBarKey,
      height: compact ? 56 : 58,
      padding: const EdgeInsets.only(
        left: EditorSpacing.lg,
        right: EditorSpacing.md,
      ),
      decoration: const BoxDecoration(
        color: EditorSurfaces.panel,
        border: Border(
          bottom: BorderSide(
            color: EditorSurfaces.divider,
            width: EditorStroke.hairline,
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(
              color: EditorSurfaces.accentSoft,
              borderRadius: EditorRadius.smAll,
            ),
            child: const Icon(
              Icons.movie_filter_outlined,
              size: 18,
              color: EditorText.primary,
            ),
          ),
          const SizedBox(width: EditorSpacing.md),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        summary?.name ?? 'muud-edits',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: EditorText.lead,
                      ),
                    ),
                    if (summary != null && summary.dirty) ...<Widget>[
                      const SizedBox(width: EditorSpacing.sm),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: EditorSurfaces.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                ),
                if (!compact)
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EditorText.caption,
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- transport

  /// 모바일 트랜스포트 한 줄: 왼쪽 되돌리기/다시 적용, 가운데 재생 + 현재/전체 시간,
  /// 오른쪽 전체화면. 줌 바는 없어졌다(타임라인은 핀치 줌).
  Widget _buildMobileTransport(BuildContext context) {
    final ProjectSummary? summary = _controller.state?.summary;
    const EditorDensity density = EditorDensity.touch;

    return Container(
      key: editorTransportKey,
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: EditorSpacing.xs),
      decoration: const BoxDecoration(
        color: EditorSurfaces.panel,
        border: Border(
          top: BorderSide(
            color: EditorSurfaces.divider,
            width: EditorStroke.hairline,
          ),
          bottom: BorderSide(
            color: EditorSurfaces.divider,
            width: EditorStroke.hairline,
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          _BarIconButton(
            tooltip: '되돌리기',
            icon: Icons.undo,
            density: density,
            iconSize: 20,
            onPressed: (summary?.canUndo ?? false) ? _controller.undo : null,
          ),
          _BarIconButton(
            tooltip: '다시 적용',
            icon: Icons.redo,
            density: density,
            iconSize: 20,
            onPressed: (summary?.canRedo ?? false) ? _controller.redo : null,
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                _BarIconButton(
                  tooltip: _playing ? '일시정지' : '재생',
                  icon: _playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  density: density,
                  iconSize: 34,
                  color: EditorSurfaces.accent,
                  onPressed: _controller.ready ? _togglePlay : null,
                ),
                const SizedBox(width: EditorSpacing.xs),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: ValueListenableBuilder<int>(
                      valueListenable: _engine.position,
                      builder:
                          (BuildContext context, int playheadMs, Widget? _) {
                            return Text(
                              '${formatTimecode(playheadMs)} / '
                              '${formatTimecode(_controller.durationMs)}',
                              style: EditorText.numeric.copyWith(fontSize: 11),
                            );
                          },
                    ),
                  ),
                ),
              ],
            ),
          ),
          _BarIconButton(
            tooltip: '전체화면',
            icon: Icons.fullscreen,
            density: density,
            iconSize: 22,
            onPressed: () => setState(() => _previewFullscreen = true),
          ),
        ],
      ),
    );
  }

  /// 트랜스포트: 왼쪽은 재생(주 행동), 오른쪽은 편집 도구. 좁은 화면에서는
  /// 도구를 오버플로 메뉴로 접어 48dp 타깃을 지킨다.
  Widget _buildTransport(BuildContext context, bool compact) {
    final double width = MediaQuery.sizeOf(context).width;
    final EditorDensity density = EditorDensity.forWidth(width);

    final Widget playCluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _BarIconButton(
          tooltip: '한 프레임 뒤로',
          icon: Icons.skip_previous,
          density: density,
          onPressed: () {
            _engine.pause();
            _controller.stepFrames(-1);
          },
        ),
        _BarIconButton(
          tooltip: _playing ? '일시정지' : '재생',
          icon: _playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
          density: density,
          iconSize: density.iconSize + 8,
          color: EditorSurfaces.accent,
          onPressed: _controller.ready ? _togglePlay : null,
        ),
        _BarIconButton(
          tooltip: '한 프레임 앞으로',
          icon: Icons.skip_next,
          density: density,
          onPressed: () {
            _engine.pause();
            _controller.stepFrames(1);
          },
        ),
      ],
    );

    // 재생 중에는 재생 헤드 값만 구독해 타임코드만 다시 그린다.
    final Widget timecodeText = ValueListenableBuilder<int>(
      valueListenable: _engine.position,
      builder: (BuildContext context, int playheadMs, Widget? child) {
        return Text(formatTimecode(playheadMs), style: EditorText.numeric);
      },
    );

    final List<Widget> tools = <Widget>[
      _BarIconButton(
        tooltip: '재생 헤드에서 분할',
        icon: Icons.content_cut,
        density: density,
        onPressed: _controller.ready
            ? () {
                _pauseForEdit();
                _controller.splitAtPlayhead();
              }
            : null,
      ),
      if (!compact) ...<Widget>[
        _BarIconButton(
          tooltip: '미디어 추가',
          icon: Icons.video_call_outlined,
          density: density,
          onPressed: _controller.ready ? _addMedia : null,
        ),
        _BarIconButton(
          tooltip: '텍스트 추가',
          icon: Icons.title,
          density: density,
          onPressed: _controller.ready ? _addText : null,
        ),
        _BarIconButton(
          tooltip: '자막 목록 · 편집',
          icon: Icons.subtitles_outlined,
          density: density,
          onPressed: _controller.ready ? _openSubtitlesSheet : null,
        ),
        _BarIconButton(
          tooltip: '자막 추가',
          icon: Icons.playlist_add,
          density: density,
          onPressed: _controller.ready ? _addSubtitle : null,
        ),
      ] else
        SizedBox(
          width: density.minTarget,
          height: density.minTarget,
          child: PopupMenuButton<String>(
            tooltip: '추가 · 편집',
            icon: const Icon(Icons.more_horiz),
            onSelected: (String value) {
              switch (value) {
                case 'media':
                  unawaited(_addMedia());
                case 'text':
                  unawaited(_addText());
                case 'subtitle':
                  unawaited(_addSubtitle());
                case 'subtitles':
                  unawaited(_openSubtitlesSheet());
              }
            },
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'media',
                    child: Text('미디어 추가'),
                  ),
                  PopupMenuItem<String>(value: 'text', child: Text('텍스트 추가')),
                  PopupMenuItem<String>(
                    value: 'subtitle',
                    child: Text('자막 추가'),
                  ),
                  PopupMenuItem<String>(
                    value: 'subtitles',
                    child: Text('자막 목록 · 편집'),
                  ),
                ],
          ),
        ),
    ];

    return Container(
      key: editorTransportKey,
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: EditorSpacing.sm),
      decoration: const BoxDecoration(
        color: EditorSurfaces.panel,
        border: Border(
          top: BorderSide(
            color: EditorSurfaces.divider,
            width: EditorStroke.hairline,
          ),
          bottom: BorderSide(
            color: EditorSurfaces.divider,
            width: EditorStroke.hairline,
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          playCluster,
          // 좁은 화면에서는 남는 폭에 맞춰 타임코드만 살짝 줄인다(타깃은 유지).
          if (compact)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: EditorSpacing.xs),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: timecodeText,
                ),
              ),
            )
          else ...<Widget>[
            Padding(
              padding: const EdgeInsets.only(left: EditorSpacing.xs),
              child: timecodeText,
            ),
            const Spacer(),
          ],
          ...tools,
        ],
      ),
    );
  }
}

/// 상단 바·트랜스포트의 아이콘 버튼. [EditorDensity] 의 최소 타깃을 지킨다.
class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.tooltip,
    required this.icon,
    required this.density,
    required this.onPressed,
    this.iconSize,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final EditorDensity density;
  final VoidCallback? onPressed;
  final double? iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: iconSize ?? density.iconSize,
      color: color,
      // 테마의 compact 밀도가 타깃을 줄이지 않게 밀도를 고정하고
      // 최소 타깃은 [EditorDensity] 가 정한다.
      visualDensity: VisualDensity.standard,
      constraints: BoxConstraints.tightFor(
        width: density.minTarget,
        height: density.minTarget,
      ),
      padding: EdgeInsets.zero,
      icon: Icon(icon),
    );
  }
}

/// 프로젝트 이름 변경 대화상자.
///
/// [TextEditingController]를 대화상자 자신이 들고 있어야 닫히는 애니메이션 중에
/// dispose 된 컨트롤러를 다시 쓰는 오류가 없다.
class _RenameProjectDialog extends StatefulWidget {
  const _RenameProjectDialog({required this.initial});

  final String initial;

  @override
  State<_RenameProjectDialog> createState() => _RenameProjectDialogState();
}

class _RenameProjectDialogState extends State<_RenameProjectDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('프로젝트 이름'),
      content: TextField(
        controller: _name,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(hintText: '예: 상하이 마라톤 하이라이트'),
        onSubmitted: (String value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_name.text),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

enum _ProjectAction { newProject, open, save }

/// 프로젝트 메뉴 — 상단 바에서 시선을 빼앗지 않도록 보조 행동을 모아 둔다.
class _ProjectMenu extends StatelessWidget {
  const _ProjectMenu({
    required this.density,
    required this.ready,
    required this.onNew,
    required this.onOpen,
    required this.onSave,
  });

  final EditorDensity density;
  final bool ready;
  final Future<void> Function() onNew;
  final Future<void> Function() onOpen;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: density.minTarget,
      height: density.minTarget,
      child: PopupMenuButton<_ProjectAction>(
        tooltip: '프로젝트 메뉴',
        icon: const Icon(Icons.folder_outlined),
        iconSize: density.iconSize,
        position: PopupMenuPosition.under,
        onSelected: (_ProjectAction action) {
          switch (action) {
            case _ProjectAction.newProject:
              unawaited(onNew());
            case _ProjectAction.open:
              unawaited(onOpen());
            case _ProjectAction.save:
              unawaited(onSave());
          }
        },
        itemBuilder: (BuildContext context) =>
            <PopupMenuEntry<_ProjectAction>>[
              PopupMenuItem<_ProjectAction>(
                value: _ProjectAction.newProject,
                enabled: ready,
                child: const _MenuRow(
                  icon: Icons.add_box_outlined,
                  label: '새로 만들기',
                ),
              ),
              PopupMenuItem<_ProjectAction>(
                value: _ProjectAction.open,
                enabled: ready,
                child: const _MenuRow(
                  icon: Icons.folder_open_outlined,
                  label: '프로젝트 열기',
                ),
              ),
              PopupMenuItem<_ProjectAction>(
                value: _ProjectAction.save,
                enabled: ready,
                child: const _MenuRow(
                  icon: Icons.save_outlined,
                  label: '저장',
                ),
              ),
            ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 16, color: EditorText.secondary),
        const SizedBox(width: EditorSpacing.sm),
        Text(label, style: EditorText.body),
      ],
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
        ? EditorSurfaces.danger
        : EditorSurfaces.success;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: const Border(
          bottom: BorderSide(
            color: EditorSurfaces.divider,
            width: EditorStroke.hairline,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        EditorSpacing.contentLine,
        EditorSpacing.sm,
        EditorSpacing.sm,
        EditorSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 15,
            color: color,
          ),
          const SizedBox(width: EditorSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: EditorText.body.copyWith(color: color),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(foregroundColor: color),
              child: Text(retryLabel ?? '다시 시도'),
            ),
          IconButton(
            onPressed: onClose,
            iconSize: 15,
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
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.86;
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        final ExportPlan? plan = controller.lastPlan;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(
                left: EditorSpacing.contentLine,
                right: EditorSpacing.contentLine,
                top: EditorSpacing.lg,
                bottom: EditorSpacing.xl,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('내보내기 계획', style: EditorText.display),
                  const SizedBox(height: EditorSpacing.xs),
                  const Text(
                    '워터마크 없음 · 하드웨어 인코더 우선',
                    style: EditorText.caption,
                  ),
                  const SizedBox(height: EditorSpacing.md),
                  const Divider(height: EditorStroke.hairline, thickness: 1),
                  EditorSection(
                    title: '플랫폼',
                    meta: controller.exportPlatform,
                    child: Wrap(
                      spacing: EditorSpacing.sm,
                      runSpacing: EditorSpacing.sm,
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
                  ),
                  EditorSection(
                    title: '계획',
                    meta: plan?.summaryLabel,
                    child: plan == null
                        ? const Text(
                            '계획을 계산하는 중…',
                            style: EditorText.caption,
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              for (final String note in plan.notes)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: EditorSpacing.xs,
                                  ),
                                  child: Text(
                                    '· $note',
                                    style: EditorText.body,
                                  ),
                                ),
                              if (controller.lastRenderPlan != null)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: EditorSpacing.sm,
                                  ),
                                  child: Text(
                                    '렌더 그래프 · '
                                    '${controller.lastRenderPlan!.frameCount}프레임 · '
                                    '영상 ${controller.lastRenderPlan!.segmentCount} / '
                                    '오디오 ${controller.lastRenderPlan!.audioSegmentCount} / '
                                    '자막 ${controller.lastRenderPlan!.subtitleCount} · '
                                    '${controller.lastRenderPlan!.digest}',
                                    style: EditorText.caption,
                                  ),
                                ),
                            ],
                          ),
                  ),
                  _ExportLimitNote(
                    state: controller.state,
                    platform: controller.exportPlatform,
                  ),
                  if (plan != null)
                    Padding(
                      padding: const EdgeInsets.only(top: EditorSpacing.lg),
                      child: Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 110),
                        padding: const EdgeInsets.all(EditorSpacing.md),
                        decoration: BoxDecoration(
                          color: EditorSurfaces.canvas,
                          borderRadius: EditorRadius.smAll,
                          border: Border.all(
                            color: EditorSurfaces.divider,
                            width: EditorStroke.hairline,
                          ),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            plan.command,
                            style: EditorText.mono,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: EditorSpacing.lg),
                  _buildProgress(context),
                  const SizedBox(height: EditorSpacing.lg),
                  Row(
                    children: <Widget>[
                      OutlinedButton(
                        onPressed: () => unawaited(controller.prepareExport()),
                        child: const Text('다시 계산'),
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
            color: EditorSurfaces.success,
            fontSize: 11,
            height: 1.4,
          ),
        );
      }
      return const SizedBox.shrink();
    }
    final Color color = progress.state == 'failed'
        ? EditorSurfaces.danger
        : (progress.state == 'completed'
              ? EditorSurfaces.success
              : EditorSurfaces.accent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '${progress.stateLabel} · ${progress.percent.toStringAsFixed(1)}%'
              ' (${progress.completedFrames}/${progress.totalFrames})',
              style: EditorText.bodyStrong.copyWith(color: color),
            ),
            const Spacer(),
            if (progress.etaLabel.isNotEmpty)
              Text(progress.etaLabel, style: EditorText.caption),
          ],
        ),
        const SizedBox(height: EditorSpacing.sm),
        ClipRRect(
          borderRadius: EditorRadius.smAll,
          child: LinearProgressIndicator(
            value: progress.fraction.clamp(0.0, 1.0),
            minHeight: 6,
          ),
        ),
        if (progress.error != null)
          Padding(
            padding: const EdgeInsets.only(top: EditorSpacing.sm),
            child: Text(
              progress.error!,
              style: EditorText.caption.copyWith(color: EditorSurfaces.danger),
            ),
          ),
        if (progress.state == 'completed') ...<Widget>[
          const SizedBox(height: EditorSpacing.md),
          Text(
            controller.exportPublished
                ? '저장 위치: ${controller.exportDisplayPath ?? controller.exportOutputPath ?? ''}'
                : '파일: ${controller.exportOutputPath ?? ''}',
            style: EditorText.body.copyWith(color: color),
          ),
          const SizedBox(height: EditorSpacing.sm),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: () => unawaited(controller.shareExport()),
                icon: const Icon(Icons.share_outlined, size: 15),
                label: const Text('공유'),
              ),
              const SizedBox(width: EditorSpacing.sm),
              OutlinedButton.icon(
                onPressed: () => unawaited(controller.openExport()),
                icon: const Icon(Icons.play_circle_outline, size: 15),
                label: const Text('열기'),
              ),
            ],
          ),
        ],
        if (progress.state == 'failed' &&
            controller.exportOutputPath != null)
          Padding(
            padding: const EdgeInsets.only(top: EditorSpacing.xs),
            child: SelectableText(
              controller.exportOutputPath!,
              style: EditorText.caption,
            ),
          ),
      ],
    );
  }
}

/// 이번 버전 내보내기의 한계를 숨기지 않고 보여 준다.
///
/// "지원하지 않는다"는 문구는 실제 구현 상태와 맞아야 한다. 지금 자막·텍스트
/// burn-in 과 사진 클립은 Windows(사진 제외)·iOS/macOS·Android 에서 동작한다.
class _ExportLimitNote extends StatelessWidget {
  const _ExportLimitNote({required this.state, required this.platform});

  final EditorState? state;

  /// 지금 고른 내보내기 플랫폼(`android`·`windows`·`macos`·`ios`).
  final String platform;

  @override
  Widget build(BuildContext context) {
    final EditorState? current = state;
    final Iterable<ClipView> clips = current == null
        ? const <ClipView>[]
        : current.tracks.expand((TrackView track) => track.clips);
    final bool hasOverlays =
        current != null &&
        (current.subtitles.isNotEmpty ||
            clips.any((ClipView clip) => clip.kind == 'text'));
    final bool hasImages = clips.any((ClipView clip) => clip.kind == 'image');
    // 영상이 올라간 시각 레이어가 둘 이상이면 Android 는 맨 아래만 합성한다.
    final int visualLayers = current == null
        ? 0
        : current.tracks
              .where(
                (TrackView track) =>
                    track.kind != 'audio' &&
                    track.clips.any(
                      (ClipView clip) =>
                          clip.kind == 'video' || clip.kind == 'image',
                    ),
              )
              .length;
    final List<String> notes = <String>[
      if (hasOverlays) '자막·텍스트는 영상 위에 새겨져 내보내집니다(burn-in).',
      if (hasImages && platform == 'windows')
        '사진 클립은 Windows 내보내기에서 아직 제외됩니다(영상만 합성).',
      if (visualLayers > 1 && platform == 'android')
        'Android 는 맨 아래 비디오 트랙을 기준으로 합성합니다(위 레이어 영상은 제외).',
      '영상·오디오 자르기/병합은 원본 화질 그대로 내보냅니다.',
    ];
    return EditorSection(
      title: '제한 사항',
      meta: platform,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final String note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: EditorSpacing.xs),
              child: Text('· $note', style: EditorText.caption),
            ),
        ],
      ),
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
    final bool compact =
        MediaQuery.sizeOf(context).width < EditorBreakpoints.compact;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: EditorSpacing.xl,
          vertical: EditorSpacing.lg,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    color: EditorSurfaces.accentSoft,
                    borderRadius: EditorRadius.mdAll,
                  ),
                  child: const Icon(
                    Icons.movie_filter_outlined,
                    color: EditorText.primary,
                    size: 28,
                  ),
                ),
              ),
              const SizedBox(height: EditorSpacing.lg),
              const Text(
                '새 프로젝트가 준비됐어요',
                textAlign: TextAlign.center,
                style: EditorText.display,
              ),
              const SizedBox(height: EditorSpacing.sm),
              const Text(
                '영상을 고르면 길이·해상도를 읽어 타임라인에 놓습니다.\n'
                '자르고, 자막을 얹고, 워터마크 없이 내보내세요.',
                textAlign: TextAlign.center,
                style: EditorText.body,
              ),
              const SizedBox(height: EditorSpacing.xl),
              FilledButton.icon(
                onPressed: onAddMedia,
                icon: const Icon(Icons.video_call_outlined, size: 18),
                label: const Text('영상 · 사진 추가'),
                style: FilledButton.styleFrom(
                  minimumSize: Size.fromHeight(compact ? 48 : 44),
                ),
              ),
              const SizedBox(height: EditorSpacing.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onAddText,
                      icon: const Icon(Icons.title, size: 16),
                      label: const Text('텍스트'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: Size(0, compact ? 48 : 36),
                      ),
                    ),
                  ),
                  const SizedBox(width: EditorSpacing.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onAddSubtitle,
                      icon: const Icon(Icons.subtitles_outlined, size: 16),
                      label: const Text('자막'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: Size(0, compact ? 48 : 36),
                      ),
                    ),
                  ),
                  const SizedBox(width: EditorSpacing.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onExport,
                      icon: const Icon(Icons.ios_share, size: 16),
                      label: const Text('내보내기'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: Size(0, compact ? 48 : 36),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: EditorSpacing.lg),
              const Divider(height: EditorStroke.hairline, thickness: 1),
              const SizedBox(height: EditorSpacing.md),
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
            padding: const EdgeInsets.only(bottom: EditorSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: EditorSurfaces.raised,
                    borderRadius: EditorRadius.smAll,
                  ),
                  child: Text(
                    number,
                    style: EditorText.caption.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: EditorSpacing.sm),
                Expanded(
                  child: Text(text, style: EditorText.caption),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 자막 목록/편집 시트.
///
/// 자막은 영상 위에 시간 범위로 얹히므로, 목록에서 문구와 구간을 직접 고칠 수
/// 있어야 한다(추가만 되고 고칠 수 없으면 실사용에서 막힌다).
class _SubtitlesSheet extends StatelessWidget {
  const _SubtitlesSheet({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        final EditorState? state = controller.state;
        final List<SubtitleView> subtitles =
            state?.subtitles ?? const <SubtitleView>[];
        final double maxHeight = MediaQuery.of(context).size.height * 0.7;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Padding(
              padding: const EdgeInsets.only(
                left: EditorSpacing.contentLine,
                right: EditorSpacing.contentLine,
                top: EditorSpacing.lg,
                bottom: EditorSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '자막 ${subtitles.length}개',
                          style: EditorText.display,
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: () async {
                          final String? text = await showDialog<String>(
                            context: context,
                            builder: (BuildContext context) =>
                                const _SubtitleEditorDialog(),
                          );
                          if (text != null && text.trim().isNotEmpty) {
                            await controller.addSubtitleHere(text.trim());
                          }
                        },
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('재생 헤드에 추가'),
                      ),
                    ],
                  ),
                  const SizedBox(height: EditorSpacing.xs),
                  const Text(
                    '자막은 재생 헤드 시각부터 2초로 추가됩니다. 문구/구간은 목록에서 고칠 수 있습니다.',
                    style: EditorText.caption,
                  ),
                  const SizedBox(height: EditorSpacing.md),
                  const Divider(height: EditorStroke.hairline, thickness: 1),
                  if (subtitles.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: EditorSpacing.xl),
                      child: Text(
                        '아직 자막이 없습니다. 재생 헤드를 원하는 위치로 옮긴 뒤 추가해 보세요.',
                        style: EditorText.body,
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: subtitles.length,
                        separatorBuilder: (BuildContext context, int index) =>
                            const Divider(height: EditorStroke.hairline),
                        itemBuilder: (BuildContext context, int index) {
                          final SubtitleView item = subtitles[index];
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(item.text, style: EditorText.bodyStrong),
                            subtitle: Text(
                              '${formatTimecode(item.startMs)} → ${formatTimecode(item.endMs)}',
                              style: EditorText.caption,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                IconButton(
                                  tooltip: '수정',
                                  iconSize: 16,
                                  onPressed: () async {
                                    final ({String text, int startMs, int endMs})?
                                    edited = await showDialog<
                                      ({String text, int startMs, int endMs})
                                    >(
                                      context: context,
                                      builder: (BuildContext context) =>
                                          _SubtitleEditorDialog(item: item),
                                    );
                                    if (edited == null ||
                                        edited.text.trim().isEmpty) {
                                      return;
                                    }
                                    await controller.updateSubtitle(
                                      id: item.id,
                                      text: edited.text.trim(),
                                      startMs: edited.startMs,
                                      endMs: edited.endMs,
                                    );
                                  },
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  tooltip: '삭제',
                                  iconSize: 16,
                                  onPressed: () =>
                                      controller.removeSubtitle(item.id),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 자막 문구/구간 편집 대화상자.
///
/// [TextEditingController]를 대화상자 자신이 들고 있으므로, 닫히는 애니메이션
/// 도중에 컨트롤러가 dispose 되어 생기는 오류가 없다.
class _SubtitleEditorDialog extends StatefulWidget {
  const _SubtitleEditorDialog({this.item});

  /// null이면 새 자막(문구만 받는다).
  final SubtitleView? item;

  @override
  State<_SubtitleEditorDialog> createState() => _SubtitleEditorDialogState();
}

class _SubtitleEditorDialogState extends State<_SubtitleEditorDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.item?.text ?? '',
  );
  late final TextEditingController _start = TextEditingController(
    text: ((widget.item?.startMs ?? 0) / 1000).toStringAsFixed(2),
  );
  late final TextEditingController _end = TextEditingController(
    text: ((widget.item?.endMs ?? 2000) / 1000).toStringAsFixed(2),
  );

  @override
  void dispose() {
    _text.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  int? _secondsToMs(String raw) {
    final double? seconds = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (seconds == null || seconds.isNaN) {
      return null;
    }
    return (seconds * 1000).round();
  }

  @override
  Widget build(BuildContext context) {
    final bool editing = widget.item != null;
    return AlertDialog(
      title: Text(editing ? '자막 수정' : '자막 추가'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _text,
              autofocus: true,
              decoration: InputDecoration(
                hintText: editing ? null : '화면 아래에 표시할 문구',
                labelText: '문구',
              ),
              onSubmitted: (_) => _submit(context),
            ),
            if (editing) ...<Widget>[
              const SizedBox(height: EditorSpacing.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _start,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '시작(초)'),
                    ),
                  ),
                  const SizedBox(width: EditorSpacing.md),
                  Expanded(
                    child: TextField(
                      controller: _end,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '끝(초)'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => _submit(context),
          child: Text(editing ? '저장' : '추가'),
        ),
      ],
    );
  }

  void _submit(BuildContext context) {
    final SubtitleView? item = widget.item;
    if (item == null) {
      Navigator.of(context).pop(_text.text);
      return;
    }
    final int start = _secondsToMs(_start.text) ?? item.startMs;
    final int end = _secondsToMs(_end.text) ?? item.endMs;
    Navigator.of(context).pop((
      text: _text.text,
      startMs: start,
      endMs: end <= start ? start + 2000 : end,
    ));
  }
}
