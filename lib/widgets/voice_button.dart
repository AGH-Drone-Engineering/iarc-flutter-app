// lib/widgets/voice_button.dart
import 'package:flutter/material.dart';

class VoiceButton extends StatelessWidget {
  /// Fired when the button is tapped (only if [available] is true).
  final VoidCallback? onPressed;

  /// Optional long-press handler (useful for push-to-talk UX).
  final VoidCallback? onLongPress;

  /// Whether speech recognition is available. If false, the button is disabled
  /// and appears grayed out.
  final bool available;

  /// Whether we are currently listening; updates icon/label with a smooth swap.
  final bool isListening;

  /// Button label when idle (defaults to "Voice").
  final String idleLabel;

  const VoiceButton({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.available = true,
    this.isListening = false,
    this.idleLabel = 'Voice',
  });

  @override
  Widget build(BuildContext context) {
    final effectiveOnPressed = available ? onPressed : null;
    final effectiveOnLongPress = available ? onLongPress : null;

    return Tooltip(
      message: available
          ? (isListening ? 'Listening…' : 'Tap to speak')
          : 'Speech recognition unavailable',
      child: ElevatedButton.icon(
        onPressed: effectiveOnPressed,
        onLongPress: effectiveOnLongPress,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: isListening
              ? const Icon(Icons.mic, key: ValueKey('mic-on'))
              : const Icon(Icons.mic_none, key: ValueKey('mic-off')),
        ),
        label: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Text(
            isListening ? 'Listening…' : idleLabel,
            key: ValueKey(isListening),
          ),
        ),
        style: ElevatedButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }
}
