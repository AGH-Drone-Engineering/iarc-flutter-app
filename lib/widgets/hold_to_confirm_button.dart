import 'package:flutter/material.dart';

class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({
    super.key,
    required this.label,
    required this.holdingLabel,
    required this.icon,
    required this.color,
    required this.onConfirmed,
    this.holdDuration = const Duration(milliseconds: 1000),
  });

  final String label;
  final String holdingLabel;
  final IconData icon;
  final Color color;
  final VoidCallback? onConfirmed;
  final Duration holdDuration;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.holdDuration,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) _fire();
    });

  bool get _enabled => widget.onConfirmed != null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _fire() {
    _controller.reset();
    widget.onConfirmed?.call();
    if (mounted) setState(() {});
  }

  void _start() {
    if (!_enabled) return;
    _controller.forward();
  }

  void _cancel() {
    if (_controller.isAnimating) _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final base = _enabled ? widget.color : Theme.of(context).disabledColor;

    return GestureDetector(
      onTapDown: (_) => _start(),
      onTapUp: (_) => _cancel(),
      onTapCancel: _cancel,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final progress = _controller.value;
          final holding = progress > 0;

          return Container(
            height: 64,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: base, width: 2),
              color: base.withValues(alpha: 0.08),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: progress,
                  child: Container(color: base.withValues(alpha: 0.35)),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(widget.icon, color: base),
                    const SizedBox(width: 10),
                    Text(
                      holding ? widget.holdingLabel : widget.label,
                      style: TextStyle(
                        color: base,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
