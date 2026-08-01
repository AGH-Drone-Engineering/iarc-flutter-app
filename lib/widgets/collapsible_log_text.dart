import 'package:flutter/material.dart';

class CollapsibleLogText extends StatefulWidget {
  const CollapsibleLogText({
    super.key,
    required this.text,
    required this.color,
    this.maxLines = 3,
  });

  final String text;
  final Color color;
  final int maxLines;

  @override
  State<CollapsibleLogText> createState() => _CollapsibleLogTextState();
}

class _CollapsibleLogTextState extends State<CollapsibleLogText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.5,
      color: widget.color,
      height: 1.3,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: widget.maxLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);

        if (!painter.didExceedMaxLines) {
          return SelectableText(widget.text, style: style);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              widget.text,
              style: style,
              maxLines: _expanded ? null : widget.maxLines,
            ),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    Text(
                      _expanded ? 'collapse' : 'expand',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
