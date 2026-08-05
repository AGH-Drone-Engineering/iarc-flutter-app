import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/map_settings.dart';

Future<void> showMapSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const MapSettingsSheet(),
  );
}

class MapSettingsSheet extends StatelessWidget {
  const MapSettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<MapSettings>();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionLabel('Ustawienia'),
            _ToggleGrid(
              children: [
                _ToggleTile(
                  icon: Icons.explore,
                  label: 'Obrót z kompasem',
                  value: settings.rotateWithCompass,
                  onChanged: settings.setRotateWithCompass,
                ),
                _ToggleTile(
                  icon: Icons.gps_fixed,
                  label: 'Śledź pozycję',
                  value: settings.snapToUser,
                  onChanged: settings.setSnapToUser,
                ),
              ],
            ),
            const SizedBox(height: 20),
            const _SectionLabel('Warstwy'),
            _ToggleGrid(
              children: [
                for (final layer in MapLayer.values)
                  _ToggleTile(
                    icon: layer.icon,
                    label: layer.label,
                    value: settings.isVisible(layer),
                    onChanged: (v) => settings.setVisible(layer, v),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _ToggleGrid extends StatelessWidget {
  const _ToggleGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GridView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        mainAxisExtent: 104,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      children: children,
    );
  }
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground =
        value ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    return Material(
      color: value ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 22, color: foreground),
                  const Spacer(),
                  Switch(
                    value: value,
                    onChanged: onChanged,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ),
              const Spacer(),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
