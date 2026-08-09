import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Draws ground-true dots whose screen size corresponds to a real-world
/// diameter in meters, independent of zoom, with a darker centred inner dot of
/// its own configurable diameter.
class GroundDotsLayer extends StatelessWidget {
  const GroundDotsLayer({
    super.key,
    required this.points,
    this.diameterMeters = 1.0,
    this.color = Colors.deepOrangeAccent,
    this.minPixelDiameter = 3.0,
    this.maxPixelDiameter = 500.0,

    this.innerDiameterMeters = 0.20,
    this.innerColor = Colors.red,
    this.innerMinPixelDiameter = 1.5,
    this.innerMaxPixelDiameter = 400.0,
  });

  final List<LatLng> points;

  /// Outer dot real-world diameter in meters.
  final double diameterMeters;
  final Color color;
  final double minPixelDiameter;
  final double maxPixelDiameter;

  /// Inner dot real-world diameter in meters (centered).
  final double innerDiameterMeters;

  /// Inner dot color; if null, a darker variant of [color] is used.
  final Color? innerColor;

  /// Clamp inner dot pixel diameter to keep it visible and sane.
  final double innerMinPixelDiameter;
  final double innerMaxPixelDiameter;

  /// Web Mercator, tileSize 256 -- hence the 256 in the denominator.
  double _metersPerPixel(double latDeg, double zoom) {
    const earthCircumference = 40075016.68557849; // meters
    final latRad = latDeg * math.pi / 180.0;
    final denom = 256.0 * math.pow(2.0, zoom);
    return (math.cos(latRad) * earthCircumference) / denom;
  }

  Color _darker(Color c, [double amount = 0.35]) {
    final hsl = HSLColor.fromColor(c);
    final l = (hsl.lightness - amount).clamp(0.0, 1.0);
    return hsl.withLightness(l).toColor();
  }

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();

    // This makes the widget rebuild whenever the camera changes (pan/zoom/rotate)
    final camera = MapCamera.of(context);
    final zoom = camera.zoom;

    final offsets = <Offset>[];
    final outerRadii = <double>[];
    final innerRadii = <double>[];

    for (final p in points) {
      final mpp = _metersPerPixel(p.latitude, zoom);

      var outerDiameterPx = diameterMeters / mpp;
      outerDiameterPx = outerDiameterPx.clamp(minPixelDiameter, maxPixelDiameter);
      final outerRadiusPx = outerDiameterPx / 2.0;

      var innerDiameterPx = innerDiameterMeters / mpp;
      innerDiameterPx = innerDiameterPx.clamp(innerMinPixelDiameter, innerMaxPixelDiameter);

      if (innerDiameterPx > outerDiameterPx) {
        innerDiameterPx = math.max(innerMinPixelDiameter, outerDiameterPx * 0.7);
      }
      final innerRadiusPx = innerDiameterPx / 2.0;

      final scr = camera.latLngToScreenOffset(p);
      offsets.add(scr);
      outerRadii.add(outerRadiusPx);
      innerRadii.add(innerRadiusPx);
    }

    final effectiveInnerColor = innerColor ?? _darker(color);

    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _GroundDotsPainter(
            offsets: offsets,
            outerRadii: outerRadii,
            innerRadii: innerRadii,
            outerColor: color,
            innerColor: effectiveInnerColor,
          ),
        ),
      ),
    );
  }
}

class _GroundDotsPainter extends CustomPainter {
  _GroundDotsPainter({
    required this.offsets,
    required this.outerRadii,
    required this.innerRadii,
    required this.outerColor,
    required this.innerColor,
  });

  final List<Offset> offsets;
  final List<double> outerRadii;
  final List<double> innerRadii;
  final Color outerColor;
  final Color innerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Paint()
      ..color = outerColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final inner = Paint()
      ..color = innerColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    for (var i = 0; i < offsets.length; i++) {
      canvas.drawCircle(offsets[i], outerRadii[i], outer);
      canvas.drawCircle(offsets[i], innerRadii[i], inner);
    }
  }

  @override
  bool shouldRepaint(covariant _GroundDotsPainter old) {
    if (old.outerColor != outerColor || old.innerColor != innerColor) return true;
    if (old.outerRadii.length != outerRadii.length ||
        old.innerRadii.length != innerRadii.length ||
        old.offsets.length != offsets.length) {
      return true;
    }
    for (var i = 0; i < outerRadii.length; i++) {
      if (old.outerRadii[i] != outerRadii[i]) return true;
      if (old.innerRadii[i] != innerRadii[i]) return true;
      if (old.offsets[i] != offsets[i]) return true;
    }
    return false;
  }
}