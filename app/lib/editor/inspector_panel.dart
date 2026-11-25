import 'package:flutter/material.dart';

import '../bridge_api.dart';
import '../models.dart';
import '../theme.dart';

/// 클립 인스펙터(선택된 클립의 속성 편집).
///
/// 모든 조작은 커맨드로 나가므로 즉시 되돌릴 수 있다.
class InspectorPanel extends StatelessWidget {
  const InspectorPanel({super.key, required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final ({TrackView track, ClipView clip})? selected = controller.selected;
    if (selected == null) {
      return const Center(
        child: Text(
          '클립을 선택하면 속성을 편집할 수 있습니다',
          style: TextStyle(color: EditorPalette.textMuted, fontSize: 12),
        ),
      );
    }

    final ClipView clip = selected.clip;
    final TrackView track = selected.track;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: EditorPalette.forClipKind(clip.kind),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                clip.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: EditorPalette.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${clip.kind} · ${track.name}',
              style: const TextStyle(
                color: EditorPalette.textMuted,
                fontSize: 10,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _InfoRow(label: '소스', value: clip.sourcePath.isEmpty ? '(텍스트)' : clip.sourcePath),
        _InfoRow(
          label: '소스 구간',
          value: '${formatTimecode(clip.startMs)} → ${formatTimecode(clip.endMs)}',
        ),
        _InfoRow(
          label: '타임라인',
          value:
              '${formatTimecode(clip.offsetMs)} → ${formatTimecode(clip.endOffsetMs)} (${formatTimecode(clip.durationMs)})',
        ),
        const SizedBox(height: 10),
        _ValueSlider(
          label: '속도',
          value: clip.speed,
          min: 0.25,
          max: 4.0,
          divisions: 15,
          display: '${clip.speed.toStringAsFixed(2)}x',
          onCommit: controller.setSpeed,
        ),
        _ValueSlider(
          label: '볼륨',
          value: clip.volume,
          min: 0,
          max: 2,
          divisions: 20,
          display: '${(clip.volume * 100).round()}%',
          onCommit: controller.setVolume,
        ),
        _ValueSlider(
          label: '불투명도',
          value: clip.opacity,
          min: 0,
          max: 1,
          divisions: 20,
          display: '${(clip.opacity * 100).round()}%',
          onCommit: controller.setOpacity,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _ActionChip(
              icon: Icons.first_page,
              label: '앞 1프레임',
              onTap: () => controller.nudgeTrim(fromStart: true, frames: 1),
            ),
            _ActionChip(
              icon: Icons.last_page,
              label: '뒤 1프레임',
              onTap: () => controller.nudgeTrim(fromStart: false, frames: 1),
            ),
            _ActionChip(
              icon: Icons.content_cut,
              label: '재생 헤드로 이동',
              onTap: controller.moveSelectedToPlayhead,
            ),
            _ActionChip(
              icon: Icons.delete_outline,
              label: '삭제',
              danger: true,
              onTap: controller.deleteSelected,
            ),
          ],
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(
                color: EditorPalette.textMuted,
                fontSize: 10,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: EditorPalette.text, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}

/// 드래그 중에는 로컬 값만 바꾸고, 손을 떼면 커맨드를 한 번만 보낸다.
class _ValueSlider extends StatefulWidget {
  const _ValueSlider({
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
  State<_ValueSlider> createState() => _ValueSliderState();
}

class _ValueSliderState extends State<_ValueSlider> {
  late double _draft = widget.value;

  @override
  void didUpdateWidget(covariant _ValueSlider oldWidget) {
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
          width: 54,
          child: Text(
            widget.label,
            style: const TextStyle(
              color: EditorPalette.textMuted,
              fontSize: 10,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: _draft.clamp(widget.min, widget.max).toDouble(),
              min: widget.min,
              max: widget.max,
              divisions: widget.divisions,
              onChanged: (double value) => setState(() => _draft = value),
              onChangeEnd: (double value) => widget.onCommit(value),
            ),
          ),
        ),
        SizedBox(
          width: 46,
          child: Text(
            widget.display,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: EditorPalette.text,
              fontSize: 10,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color color = danger ? EditorPalette.playhead : EditorPalette.text;
    return Material(
      color: EditorPalette.surfaceHigh,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 5),
              Text(label, style: TextStyle(color: color, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}
