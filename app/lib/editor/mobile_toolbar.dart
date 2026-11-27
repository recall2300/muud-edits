import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge_api.dart';
import '../models.dart';
import '../theme.dart';

/// 모바일 하단 툴바 키(테스트·레이아웃 계약).
const Key mobileToolbarKey = ValueKey<String>('mobile-bottom-toolbar');
const Key mobileToolbarScrollerKey = ValueKey<String>('mobile-bottom-scroller');
const Key mobilePanelKey = ValueKey<String>('mobile-inline-panel');

/// 모바일 툴바에서 열리는 컴팩트 패널.
enum MobilePanel { none, volume, speed, trim, text, style, adjust }

/// Meta Edits 스타일 하단 가로 스크롤 컨텍스트 툴바.
///
/// * 아무것도 선택하지 않았으면 **메인 툴바**(미디어·오디오·텍스트·오버레이·자막·조정).
/// * 클립을 선택하면 `<`(선택 해제) + 그 클립 종류에 맞는 액션만 보여 준다.
/// * 볼륨·속도·트림·텍스트 같은 세부 조절은 타임라인과 툴바 사이의 **인라인 패널**로
///   열린다(프리뷰를 가리지 않는다).
///
/// 모든 편집은 [EditorController]를 거쳐 코어 커맨드로 나가므로 되돌릴 수 있다.
class MobileToolbar extends StatefulWidget {
  const MobileToolbar({
    super.key,
    required this.controller,
    required this.onAddMedia,
    required this.onAddAudio,
    required this.onAddText,
    required this.onAddOverlay,
    required this.onAddSubtitle,
  });

  final EditorController controller;
  final VoidCallback onAddMedia;
  final VoidCallback onAddAudio;
  final VoidCallback onAddText;
  final VoidCallback onAddOverlay;
  final VoidCallback onAddSubtitle;

  @override
  State<MobileToolbar> createState() => _MobileToolbarState();
}

class _MobileToolbarState extends State<MobileToolbar> {
  MobilePanel _panel = MobilePanel.none;
  String? _panelClipId;

  EditorController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// 다른 클립을 고르면 이전 클립의 패널을 닫는다(엉뚱한 클립을 고치는 일 방지).
  void _onControllerChanged() {
    final String? selected = _controller.selectedClipId;
    if (_panel != MobilePanel.none &&
        _panelClipId != null &&
        selected != _panelClipId) {
      setState(() {
        _panel = MobilePanel.none;
        _panelClipId = null;
      });
    }
  }

  void _openPanel(MobilePanel panel) {
    final String? clipId = _controller.selectedClipId;
    setState(() {
      if (_panel == panel && _panelClipId == clipId) {
        _panel = MobilePanel.none;
        _panelClipId = null;
      } else {
        _panel = panel;
        _panelClipId = clipId;
      }
    });
  }

  void _closePanel() {
    setState(() {
      _panel = MobilePanel.none;
      _panelClipId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, Widget? child) {
        final ({TrackView track, ClipView clip})? selected = _controller.selected;
        return Container(
          key: mobileToolbarKey,
          decoration: const BoxDecoration(
            color: EditorSurfaces.panel,
            border: Border(
              top: BorderSide(
                color: EditorSurfaces.divider,
                width: EditorStroke.hairline,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_panel != MobilePanel.none && selected != null)
                _InlinePanel(
                  key: mobilePanelKey,
                  panel: _panel,
                  controller: _controller,
                  track: selected.track,
                  clip: selected.clip,
                  onClose: _closePanel,
                ),
              _buildActionBar(selected),
            ],
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ 툴바

  Widget _buildActionBar(({TrackView track, ClipView clip})? selected) {
    final List<Widget> actions = selected == null
        ? <Widget>[
            _ToolButton(
              icon: Icons.video_call_outlined,
              label: '미디어 추가',
              onTap: widget.onAddMedia,
            ),
            _ToolButton(
              icon: Icons.music_note_outlined,
              label: '오디오',
              onTap: widget.onAddAudio,
            ),
            _ToolButton(
              icon: Icons.title,
              label: '텍스트',
              onTap: widget.onAddText,
            ),
            _ToolButton(
              icon: Icons.layers_outlined,
              label: '오버레이',
              onTap: widget.onAddOverlay,
            ),
            _ToolButton(
              icon: Icons.subtitles_outlined,
              label: '자막',
              onTap: widget.onAddSubtitle,
            ),
            _ToolButton(
              icon: Icons.tune,
              label: '필터·조정',
              onTap: _adjustAtPlayhead,
            ),
          ]
        : <Widget>[
            _ToolButton(
              icon: Icons.chevron_left,
              label: '뒤로',
              tooltip: '선택 해제',
              onTap: () {
                _closePanel();
                _controller.selectClip(null);
              },
            ),
            ..._contextActions(selected.track, selected.clip),
          ];

    return SizedBox(
      height: 62,
      child: SingleChildScrollView(
        key: mobileToolbarScrollerKey,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: EditorSpacing.sm),
        child: Row(
          children: <Widget>[
            for (int index = 0; index < actions.length; index++) ...<Widget>[
              if (index > 0) const SizedBox(width: EditorSpacing.xs),
              actions[index],
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _contextActions(TrackView track, ClipView clip) {
    final bool isText = clip.kind == 'text';
    final bool isVideo = clip.kind == 'video';
    final bool isImage = clip.kind == 'image';
    final bool isAudio = clip.kind == 'audio';

    return <Widget>[
      if (isText)
        _ToolButton(
          icon: Icons.edit_outlined,
          label: '수정',
          selected: _panel == MobilePanel.text,
          onTap: () => _openPanel(MobilePanel.text),
        ),
      _ToolButton(
        icon: Icons.content_cut,
        label: '분할',
        onTap: () {
          _closePanel();
          unawaited(_controller.splitSelectedAtPlayhead());
        },
      ),
      if (isText)
        _ToolButton(
          icon: Icons.format_size,
          label: '스타일',
          selected: _panel == MobilePanel.style,
          onTap: () => _openPanel(MobilePanel.style),
        ),
      if (isVideo || isAudio)
        _ToolButton(
          icon: Icons.speed,
          label: '속도',
          selected: _panel == MobilePanel.speed,
          onTap: () => _openPanel(MobilePanel.speed),
        ),
      if (isVideo || isAudio)
        _ToolButton(
          icon: Icons.volume_up_outlined,
          label: '볼륨',
          selected: _panel == MobilePanel.volume,
          onTap: () => _openPanel(MobilePanel.volume),
        ),
      if (isImage)
        _ToolButton(
          icon: Icons.opacity,
          label: '불투명도',
          selected: _panel == MobilePanel.adjust,
          onTap: () => _openPanel(MobilePanel.adjust),
        ),
      if (isVideo)
        _ToolButton(
          icon: Icons.graphic_eq,
          label: '오디오 추출',
          onTap: () {
            _closePanel();
            unawaited(_controller.extractAudioFromSelected());
          },
        ),
      _ToolButton(
        icon: Icons.crop,
        label: '트림',
        selected: _panel == MobilePanel.trim,
        onTap: () => _openPanel(MobilePanel.trim),
      ),
      _ToolButton(
        icon: Icons.copy_all_outlined,
        label: '복제',
        onTap: () {
          _closePanel();
          unawaited(_controller.duplicateSelected());
        },
      ),
      if (isText || isImage)
        _ToolButton(
          icon: Icons.tune,
          label: '조정',
          selected: _panel == MobilePanel.adjust,
          onTap: () => _openPanel(MobilePanel.adjust),
        ),
      _ToolButton(
        icon: Icons.delete_outline,
        label: '삭제',
        danger: true,
        onTap: () {
          _closePanel();
          unawaited(_controller.deleteSelected());
        },
      ),
    ];
  }

  /// 재생 헤드 위 클립을 골라 조정 패널을 연다(선택이 없을 때 메인 툴바에서).
  void _adjustAtPlayhead() {
    final ({TrackView track, ClipView clip})? hit = _controller.clipAtPlayhead();
    final BuildContext? context = mounted ? this.context : null;
    if (hit == null) {
      setState(() {
        _panel = MobilePanel.none;
        _panelClipId = null;
      });
      if (context != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('재생 헤드 위에 클립이 없습니다')),
        );
      }
      return;
    }
    _controller.selectClip(hit.clip.id);
    setState(() {
      _panel = MobilePanel.adjust;
      _panelClipId = hit.clip.id;
    });
  }
}

/// 아이콘 + 라벨 (48dp 타깃).
class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.danger = false,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool danger;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Color color = danger
        ? EditorSurfaces.danger
        : (selected ? EditorPalette.accent : EditorText.secondary);
    final Widget button = InkWell(
      key: ValueKey<String>('mobile-tool-$label'),
      onTap: onTap,
      borderRadius: EditorRadius.smAll,
      child: SizedBox(
        width: 60,
        height: 56,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 26,
              height: 24,
              decoration: BoxDecoration(
                color: selected
                    ? EditorSurfaces.accentSoft
                    : Colors.transparent,
                borderRadius: EditorRadius.smAll,
              ),
              child: Icon(icon, size: 19, color: color),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                height: 1.1,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? EditorPalette.accent : EditorText.secondary,
              ),
            ),
          ],
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 타임라인 아래·툴바 위에 열리는 컴팩트 인라인 패널.
class _InlinePanel extends StatelessWidget {
  const _InlinePanel({
    super.key,
    required this.panel,
    required this.controller,
    required this.track,
    required this.clip,
    required this.onClose,
  });

  final MobilePanel panel;
  final EditorController controller;
  final TrackView track;
  final ClipView clip;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final String title = switch (panel) {
      MobilePanel.volume => '볼륨',
      MobilePanel.speed => '속도',
      MobilePanel.trim => '트림',
      MobilePanel.text => '텍스트',
      MobilePanel.style => '스타일',
      MobilePanel.adjust => '조정',
      MobilePanel.none => '',
    };
    return Container(
      constraints: const BoxConstraints(maxHeight: 196),
      decoration: const BoxDecoration(
        color: EditorSurfaces.raised,
        border: Border(
          bottom: BorderSide(
            color: EditorSurfaces.divider,
            width: EditorStroke.hairline,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        EditorSpacing.md,
        EditorSpacing.sm,
        EditorSpacing.sm,
        EditorSpacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(title, style: EditorText.section),
              const Spacer(),
              IconButton(
                tooltip: '패널 닫기',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              child: switch (panel) {
                MobilePanel.volume => _VolumePanel(
                  controller: controller,
                  clip: clip,
                ),
                MobilePanel.speed => _SpeedPanel(
                  controller: controller,
                  clip: clip,
                ),
                MobilePanel.trim => _TrimPanel(
                  controller: controller,
                  clip: clip,
                ),
                MobilePanel.text => _TextPanel(controller: controller, clip: clip),
                MobilePanel.style => _StylePanel(
                  controller: controller,
                  clip: clip,
                ),
                MobilePanel.adjust => _AdjustPanel(
                  controller: controller,
                  clip: clip,
                ),
                MobilePanel.none => const SizedBox.shrink(),
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 슬라이더 한 줄(드래그 중 로컬, 손을 떼면 커맨드 한 번).
class _PanelSlider extends StatefulWidget {
  const _PanelSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onCommit,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final int? divisions;
  final Future<void> Function(double value) onCommit;

  @override
  State<_PanelSlider> createState() => _PanelSliderState();
}

class _PanelSliderState extends State<_PanelSlider> {
  late double _draft = widget.value;

  @override
  void didUpdateWidget(covariant _PanelSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _draft = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 56,
          child: Text(widget.label, style: EditorText.label),
        ),
        Expanded(
          child: Slider(
            value: _draft.clamp(widget.min, widget.max).toDouble(),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            onChanged: (double value) => setState(() => _draft = value),
            onChangeEnd: (double value) => widget.onCommit(value),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            widget.display,
            textAlign: TextAlign.right,
            style: EditorText.numeric,
          ),
        ),
      ],
    );
  }
}

class _VolumePanel extends StatelessWidget {
  const _VolumePanel({required this.controller, required this.clip});

  final EditorController controller;
  final ClipView clip;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _PanelSlider(
          label: '볼륨',
          value: clip.volume,
          min: 0,
          max: 2,
          divisions: 20,
          display: '${(clip.volume * 100).round()}%',
          onCommit: controller.setVolume,
        ),
        _PanelSlider(
          label: '페이드 인',
          value: clip.fadeInMs.toDouble(),
          min: 0,
          max: 3000,
          divisions: 30,
          display: '${(clip.fadeInMs / 1000).toStringAsFixed(1)}s',
          onCommit: (double value) => controller.apply(
            <String, dynamic>{
              'type': 'set_clip_fades',
              'track_id': _trackIdOf(controller, clip.id) ?? '',
              'clip_id': clip.id,
              'fade_in_ms': value.round(),
              'fade_out_ms': clip.fadeOutMs,
            },
          ),
        ),
        _PanelSlider(
          label: '페이드 아웃',
          value: clip.fadeOutMs.toDouble(),
          min: 0,
          max: 3000,
          divisions: 30,
          display: '${(clip.fadeOutMs / 1000).toStringAsFixed(1)}s',
          onCommit: (double value) => controller.apply(
            <String, dynamic>{
              'type': 'set_clip_fades',
              'track_id': _trackIdOf(controller, clip.id) ?? '',
              'clip_id': clip.id,
              'fade_in_ms': clip.fadeInMs,
              'fade_out_ms': value.round(),
            },
          ),
        ),
      ],
    );
  }
}

class _SpeedPanel extends StatelessWidget {
  const _SpeedPanel({required this.controller, required this.clip});

  final EditorController controller;
  final ClipView clip;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _PanelSlider(
          label: '배속',
          value: clip.speed,
          min: 0.25,
          max: 4,
          divisions: 15,
          display: '${clip.speed.toStringAsFixed(2)}x',
          onCommit: controller.setSpeed,
        ),
        const SizedBox(height: EditorSpacing.xs),
        Wrap(
          spacing: EditorSpacing.sm,
          children: <Widget>[
            for (final double preset in <double>[0.5, 1.0, 1.5, 2.0])
              ChoiceChip(
                label: Text('${preset}x'),
                selected: (clip.speed - preset).abs() < 0.01,
                onSelected: (bool selected) {
                  if (selected) {
                    unawaited(controller.setSpeed(preset));
                  }
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _TrimPanel extends StatelessWidget {
  const _TrimPanel({required this.controller, required this.clip});

  final EditorController controller;
  final ClipView clip;

  @override
  Widget build(BuildContext context) {
    final int maxEnd = (clip.sourceDurationMs ?? clip.endMs) > clip.startMs + 34
        ? (clip.sourceDurationMs ?? clip.endMs)
        : clip.startMs + 35;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _PanelSlider(
          label: '시작',
          value: clip.startMs.toDouble(),
          min: 0,
          max: (clip.endMs - 34).clamp(1, double.infinity).toDouble(),
          display: formatTimecode(clip.startMs),
          onCommit: (double value) => controller.trimClip(startMs: value.round()),
        ),
        _PanelSlider(
          label: '끝',
          value: clip.endMs.toDouble(),
          min: (clip.startMs + 34).toDouble(),
          max: maxEnd.toDouble(),
          display: formatTimecode(clip.endMs),
          onCommit: (double value) => controller.trimClip(endMs: value.round()),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => unawaited(
                  controller.nudgeTrim(fromStart: true, frames: 1),
                ),
                icon: const Icon(Icons.first_page, size: 14),
                label: const Text('앞 1f'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34)),
              ),
            ),
            const SizedBox(width: EditorSpacing.xs),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => unawaited(
                  controller.nudgeTrim(fromStart: false, frames: 1),
                ),
                icon: const Icon(Icons.last_page, size: 14),
                label: const Text('뒤 1f'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34)),
              ),
            ),
            const SizedBox(width: EditorSpacing.xs),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: controller.moveSelectedToPlayhead,
                icon: const Icon(Icons.vertical_align_center, size: 14),
                label: const Text('헤드로'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TextPanel extends StatefulWidget {
  const _TextPanel({required this.controller, required this.clip});

  final EditorController controller;
  final ClipView clip;

  @override
  State<_TextPanel> createState() => _TextPanelState();
}

class _TextPanelState extends State<_TextPanel> {
  late final TextEditingController _text = TextEditingController(
    text: widget.clip.textContent ?? '',
  );
  late String _clipId = widget.clip.id;

  @override
  void didUpdateWidget(covariant _TextPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.clip.id != _clipId) {
      _clipId = widget.clip.id;
      _text.text = widget.clip.textContent ?? '';
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _commit() {
    final String value = _text.text.trim();
    if (value.isEmpty) {
      return;
    }
    unawaited(widget.controller.setTextClipStyle(widget.clip, content: value));
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: _text,
            style: EditorText.body,
            decoration: const InputDecoration(hintText: '화면에 표시할 문구'),
            onSubmitted: (_) => _commit(),
          ),
        ),
        const SizedBox(width: EditorSpacing.sm),
        FilledButton(
          onPressed: _commit,
          style: FilledButton.styleFrom(minimumSize: const Size(56, 40)),
          child: const Text('적용'),
        ),
      ],
    );
  }
}

class _StylePanel extends StatelessWidget {
  const _StylePanel({required this.controller, required this.clip});

  final EditorController controller;
  final ClipView clip;

  static const List<String> _colors = <String>[
    '#FFFFFFFF',
    '#FFE066FF',
    '#FF4D6DFF',
    '#7C5CFFFF',
  ];

  @override
  Widget build(BuildContext context) {
    final double size = clip.textSizePx ?? 64;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _PanelSlider(
          label: '크기',
          value: size,
          min: 24,
          max: 140,
          divisions: 23,
          display: '${size.round()}px',
          onCommit: (double value) => controller.setTextClipStyle(
            clip,
            sizePx: value,
            color: clip.textColor,
          ),
        ),
        Row(
          children: <Widget>[
            Text('색', style: EditorText.label),
            const SizedBox(width: EditorSpacing.md),
            for (final String color in _colors)
              Padding(
                padding: const EdgeInsets.only(right: EditorSpacing.sm),
                child: InkWell(
                  onTap: () => unawaited(
                    controller.setTextClipStyle(clip, sizePx: size, color: color),
                  ),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _parseColor(color),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: (clip.textColor ?? '#FFFFFFFF') == color
                            ? EditorPalette.accent
                            : EditorSurfaces.divider,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: EditorSpacing.xs),
        _PanelSlider(
          label: '불투명',
          value: clip.opacity,
          min: 0,
          max: 1,
          divisions: 20,
          display: '${(clip.opacity * 100).round()}%',
          onCommit: controller.setOpacity,
        ),
      ],
    );
  }
}

class _AdjustPanel extends StatelessWidget {
  const _AdjustPanel({required this.controller, required this.clip});

  final EditorController controller;
  final ClipView clip;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _PanelSlider(
          label: '불투명',
          value: clip.opacity,
          min: 0,
          max: 1,
          divisions: 20,
          display: '${(clip.opacity * 100).round()}%',
          onCommit: controller.setOpacity,
        ),
        if (clip.kind == 'video' || clip.kind == 'audio')
          _PanelSlider(
            label: '볼륨',
            value: clip.volume,
            min: 0,
            max: 2,
            divisions: 20,
            display: '${(clip.volume * 100).round()}%',
            onCommit: controller.setVolume,
          ),
      ],
    );
  }
}

Color _parseColor(String hex) {
  String text = hex.trim();
  if (text.startsWith('#')) {
    text = text.substring(1);
  }
  if (text.length == 6) {
    text = '${text}FF';
  }
  final int? value = int.tryParse(text, radix: 16);
  return value == null ? Colors.white : Color(value);
}

String? _trackIdOf(EditorController controller, String clipId) {
  final EditorState? state = controller.state;
  if (state == null) {
    return null;
  }
  for (final TrackView track in state.tracks) {
    for (final ClipView clip in track.clips) {
      if (clip.id == clipId) {
        return track.id;
      }
    }
  }
  return null;
}
