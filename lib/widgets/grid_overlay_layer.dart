import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../pathfinding/field_grid.dart';
import '../pathfinding/grid_path.dart';

/// Kolory komórek siatki. Jedno miejsce, bo legenda musi się zgadzać z mapą.
class GridPalette {
  const GridPalette({
    this.safe = const Color(0x1AFFFFFF),
    this.outside = const Color(0x0D000000),
    this.zone = const Color(0x6656C271),
    this.path = const Color(0xCC2E6FF2),
    this.mine = const Color(0xCCE53935),
    this.mineOnPath = const Color(0xFFFF6D00),
    this.unscanned = const Color(0xFF6D4C41),
    this.gridLine = const Color(0x22FFFFFF),
  });

  final Color safe;
  final Color outside;
  final Color zone;
  final Color path;
  final Color mine;

  /// Mina na niebieskiej linii -- zeruje wynik, więc musi być nie do przeoczenia.
  final Color mineOnPath;

  /// Teren nierozpoznany. Im mniej przeskanowany, tym gęściej kryje mapę.
  final Color unscanned;

  final Color gridLine;
}

/// Rysuje siatkę komórek 2x2 stopy na mapie.
///
/// Wzoruje się na [GroundDotsLayer]: `MapCamera.of(context)` zapisuje widget na
/// zmiany kamery, a rzutowanie idzie przez `camera.latLngToScreenOffset`.
///
/// Komórki nie są rzutowane pojedynczo. Trzy punkty siatki wystarczą, żeby
/// odtworzyć jej odwzorowanie na ekran jako przekształcenie afiniczne -- przy
/// polu wielkości stu metrów zniekształcenie Mercatora jest pomijalne. Dzięki
/// temu 6000 komórek rysuje się kilkoma wywołaniami `drawPath`, a nie sześcioma
/// tysiącami.
class GridOverlayLayer extends StatelessWidget {
  const GridOverlayLayer({
    super.key,
    required this.mapping,
    required this.field,
    this.pathCells = const [],
    this.zoneCells = const {},
    this.coverage,
    this.palette = const GridPalette(),
    this.showSafeCells = true,
    this.showCoverage = true,
  });

  final FieldMapping mapping;
  final GridField field;
  final List<Cell> pathCells;
  final Set<Cell> zoneCells;

  /// Maski próbek pokrycia z [MappedField.coverage]. Pusta lub `null`, gdy
  /// żaden dron nie zgłosił jeszcze skanu.
  final Uint16List? coverage;

  final GridPalette palette;
  final bool showSafeCells;
  final bool showCoverage;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final origin = camera.latLngToScreenOffset(
      mapping.cellCorners(const Cell(0, 0))[0],
    );
    final alongU = camera.latLngToScreenOffset(
      mapping.cellCorners(const Cell(0, 0))[1],
    );
    final alongV = camera.latLngToScreenOffset(
      mapping.cellCorners(const Cell(0, 0))[3],
    );

    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _GridPainter(
            origin: origin,
            du: alongU - origin,
            dv: alongV - origin,
            field: field,
            pathCells: pathCells,
            zoneCells: zoneCells,
            coverage: coverage,
            palette: palette,
            showSafeCells: showSafeCells,
            showCoverage: showCoverage,
          ),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.origin,
    required this.du,
    required this.dv,
    required this.field,
    required this.pathCells,
    required this.zoneCells,
    required this.coverage,
    required this.palette,
    required this.showSafeCells,
    required this.showCoverage,
  });

  final Offset origin;
  final Offset du;
  final Offset dv;
  final GridField field;
  final List<Cell> pathCells;
  final Set<Cell> zoneCells;
  final Uint16List? coverage;
  final GridPalette palette;
  final bool showSafeCells;
  final bool showCoverage;

  /// Liczba przedziałów gradientu pokrycia.
  ///
  /// Pokrycie jest próbkowane w 1/16, ale rysowanie szesnastu warstw nic nie
  /// wnosi -- oko i tak nie odróżni sąsiednich. Pięć przedziałów wystarcza, żeby
  /// było widać, gdzie skan tylko liznął komórkę, a gdzie prawie ją domknął.
  static const int _coverageBuckets = 5;

  /// Poniżej tego rozmiaru komórki wypełnienie i tak nie jest czytelne, a
  /// kosztuje tyle samo. Rysujemy wtedy tylko to, co niesie informację.
  static const double _minCellPixels = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final cellPixels = du.distance;
    final onPath = pathCells.toSet();

    final safe = Path();
    final outside = Path();
    final zone = Path();
    final path = Path();
    final mine = Path();
    final mineOnPath = Path();
    final unscanned = List.generate(_coverageBuckets, (_) => Path());

    final detailed = cellPixels >= _minCellPixels;
    final bits = coverage;
    final hasCoverage = showCoverage && bits != null && bits.isNotEmpty;

    for (var y = 0; y < field.rows; y++) {
      for (var x = 0; x < field.cols; x++) {
        final cell = Cell(x, y);
        final isMine = field.mines.contains(cell);
        final isPath = onPath.contains(cell);

        if (isMine && isPath) {
          _addCell(mineOnPath, x, y);
          continue;
        }
        if (isMine) {
          _addCell(mine, x, y);
          continue;
        }
        if (isPath) {
          _addCell(path, x, y);
          continue;
        }
        if (zoneCells.contains(cell)) {
          _addCell(zone, x, y);
          continue;
        }
        if (field.outside.contains(cell)) {
          if (detailed) _addCell(outside, x, y);
          continue;
        }
        if (hasCoverage && field.unscanned.contains(cell)) {
          if (!detailed) continue;
          final fraction = _coverageFraction(bits[y * field.cols + x]);
          final bucket = ((1.0 - fraction) * (_coverageBuckets - 1)).round();
          _addCell(unscanned[bucket.clamp(0, _coverageBuckets - 1)], x, y);
          continue;
        }
        if (detailed && showSafeCells) _addCell(safe, x, y);
      }
    }

    final brush = Paint()..style = PaintingStyle.fill;
    for (final (shape, color) in [
      (outside, palette.outside),
      (safe, palette.safe),
      for (var i = 0; i < _coverageBuckets; i++)
        (
          unscanned[i],
          palette.unscanned.withValues(
            alpha: 0.15 + 0.55 * i / (_coverageBuckets - 1),
          ),
        ),
      (zone, palette.zone),
      (path, palette.path),
      (mine, palette.mine),
      (mineOnPath, palette.mineOnPath),
    ]) {
      brush.color = color;
      canvas.drawPath(shape, brush);
    }

    if (cellPixels >= 6.0) {
      canvas.drawPath(
        safe,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = palette.gridLine,
      );
    }
  }

  double _coverageFraction(int bits) {
    var count = 0;
    for (var i = 0; i < 16; i++) {
      if (bits & (1 << i) != 0) count++;
    }
    return count / 16.0;
  }

  void _addCell(Path target, int x, int y) {
    final base = origin + du * x.toDouble() + dv * y.toDouble();
    target.addPolygon([base, base + du, base + du + dv, base + dv], true);
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.origin != origin ||
      old.du != du ||
      old.dv != dv ||
      !identical(old.field, field) ||
      !identical(old.pathCells, pathCells) ||
      !identical(old.zoneCells, zoneCells) ||
      !identical(old.coverage, coverage) ||
      old.showSafeCells != showSafeCells ||
      old.showCoverage != showCoverage;
}
