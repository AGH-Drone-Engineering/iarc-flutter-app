/// Odwzorowanie zmierzonego pola (GPS) na siatkę komórek 2x2 stopy.
///
/// Port `minefield_path/fieldmap.py`. Siatka *nie* jest zakładana jako 40x150
/// ani wyrównana do północy. Wynika ze zmierzonych narożników:
///
/// 1. rzut narożników i min na lokalny płaski układ XY,
/// 2. wybór linii startu -- bok najbliższy obserwatorowi (telefonowi),
/// 3. wykrycie źle zmierzonego narożnika, jeśli pozostałe trzy trzymają kąt
///    prosty,
/// 4. pokrycie prostokąta otaczającego komórkami,
/// 5. odcięcie komórek, które nie mają nic wspólnego z obrysem pola.
///
/// Komórka należy do pola, gdy ma z obrysem *jakąkolwiek* część wspólną -- pola
/// nie da się zmierzyć co do stopy, więc lepiej pokazać komórkę brzegową niż
/// zgubić przejście przy krawędzi.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import 'grid_path.dart';
import 'local_frame.dart';

/// Zabezpieczenie przed literówką w narożniku, która rozdmuchałaby siatkę.
const int maxGridCells = 400000;

/// Dopuszczalny |cos| kąta w narożniku uznawanym za prosty (~3 stopnie).
const double squarenessTolerance = 0.05;

/// Poniżej tego rozjazdu narożnik uznajemy za dobry -- to poziom szumu GPS.
const double cornerErrorMeters = 1.5;

/// Powyżej tego rozjazdu narożnika nie ruszamy.
///
/// Geometria sama nie odróżnia "prostokąt z jednym źle zmierzonym narożnikiem"
/// od "pole naprawdę jest trapezem" -- oba dają ten sam test. Rozstrzyga skala:
/// pomyłka GPS to metry, a trapez to kilkanaście metrów. Powyżej progu kształt
/// zostaje, a operator dostaje ostrzeżenie i decyduje sam.
const double maxCornerFixMeters = 8.0;

/// Siatka oficjalnego pola z Huntsville -- 80 x 300 stóp.
const (int, int) officialGridSize = (officialCols, officialRows);

/// Ile procent zmierzone pole może odstawać od 80 x 300 stóp i nadal liczyć się
/// jako pole zawodowe.
///
/// Hojnie: cztery rogi zdjęte telefonem to metry błędu, a nie centymetry, i
/// pomyłka na tym poziomie nie zmienia tego, że mierzymy pole zawodowe.
const double officialFieldTolerance = 0.10;

/// Czy to jest (z grubsza) pole zawodowe 80 x 300 stóp.
///
/// Rozstrzyga, którą siatką je pokryć, i dlatego nie jest kosmetyką:
///
/// * **pole zawodowe** -> wymuszone 40 x 150 komórek. Zmierzony bok nigdy nie
///   wychodzi równo na 2 stopy, a `path.txt` musi trafić w siatkę sędziowską co
///   do komórki, więc dzielimy pomiar na dokładnie tyle części, ile ma scorer.
/// * **dowolne pole testowe** -> komórki 2x2 stopy i tyle kolumn/wierszy, ile
///   się zmieści. Wymuszenie 40 x 150 na polu 400 x 90 m rozciąga komórkę do
///   10 x 0.6 m: siatka przestaje być siatką kwadratów, a to, co widać na mapie,
///   przestaje mieć cokolwiek wspólnego z tym, po czym idzie człowiek.
bool fieldMatchesOfficial(List<LatLng> corners,
    {double tolerance = officialFieldTolerance}) {
  if (corners.length < 3) return true;   // nic nie wiemy - nie zmieniaj domyślnej
  final frame = LocalFrame.fromPoints(corners);
  final polygon = asCcw(frame.manyToXy(corners));
  final sides = [
    for (var i = 0; i < polygon.length; i++)
      distanceBetween(polygon[i], polygon[(i + 1) % polygon.length]),
  ]..sort();

  // Mediana krótszej i dłuższej pary, żeby jeden odstający róg nie decydował.
  final shortSide = (sides.first + sides[1]) / 2.0;
  final longSide = (sides[sides.length - 2] + sides.last) / 2.0;
  final wantShort = officialCols * cellMeters;    // 80 stóp
  final wantLong = officialRows * cellMeters;     // 300 stóp
  return (shortSide - wantShort).abs() <= wantShort * tolerance &&
      (longSide - wantLong).abs() <= wantLong * tolerance;
}

/// Przeliczenie GPS <-> komórka siatki.
///
/// Układ siatki: początek w lewym narożniku linii startu, [axisX] wzdłuż linii
/// startu, [axisY] w głąb pola.
///
/// [cellU] i [cellV] są osobne, bo tryb zawodowy narzuca dokładnie 40x150
/// komórek i dzieli zmierzone pole na tyle części -- zmierzony bok nigdy nie
/// wychodzi równo na 2 stopy, a plik path.txt musi trafić w siatkę symulatora
/// co do komórki.
class FieldMapping {
  const FieldMapping({
    required this.frame,
    required this.origin,
    required this.axisX,
    required this.axisY,
    required this.cols,
    required this.rows,
    this.cellU = cellMeters,
    this.cellV = cellMeters,
  });

  final LocalFrame frame;
  final Vec2 origin;
  final Vec2 axisX;
  final Vec2 axisY;
  final int cols;
  final int rows;
  final double cellU;
  final double cellV;

  Vec2 toUv(Vec2 xy) {
    final d = xy - origin;
    return Vec2(d.x * axisX.x + d.y * axisX.y, d.x * axisY.x + d.y * axisY.y);
  }

  Vec2 toXy(Vec2 uv) => Vec2(
    origin.x + uv.x * axisX.x + uv.y * axisY.x,
    origin.y + uv.x * axisX.y + uv.y * axisY.y,
  );

  Cell? cellOfXy(Vec2 xy) {
    final uv = toUv(xy);
    final x = (uv.x / cellU).floor();
    final y = (uv.y / cellV).floor();
    if (x >= 0 && x < cols && y >= 0 && y < rows) return Cell(x, y);
    return null;
  }

  Cell? cellOfLatLng(LatLng p) => cellOfXy(frame.toXy(p));

  LatLng cellCenter(Cell cell) => frame.toLatLng(
    toXy(Vec2((cell.x + 0.5) * cellU, (cell.y + 0.5) * cellV)),
  );

  /// Cztery rogi komórki -- do rysowania kwadratu na mapie.
  List<LatLng> cellCorners(Cell cell) => [
    for (final (du, dv) in const [(0, 0), (1, 0), (1, 1), (0, 1)])
      frame.toLatLng(toXy(Vec2((cell.x + du) * cellU, (cell.y + dv) * cellV))),
  ];

  List<LatLng> pathLatLng(List<Cell> cells) => [
    for (final c in cells) cellCenter(c),
  ];
}

/// Prostokąt zgłoszony przez drona jako przeskanowany (komunikat `SCAN`).
///
/// Osiowany w lat/lon, zadany dwoma przeciwległymi narożnikami w dowolnej
/// kolejności. W układzie siatki wypada jako obrócony prostokąt, bo siatka
/// trzyma się linii startu, a nie południka.
class ScanRegion {
  const ScanRegion(this.a, this.b);

  final LatLng a;
  final LatLng b;

  List<LatLng> get corners {
    final latLo = math.min(a.latitude, b.latitude);
    final latHi = math.max(a.latitude, b.latitude);
    final lonLo = math.min(a.longitude, b.longitude);
    final lonHi = math.max(a.longitude, b.longitude);
    return [
      LatLng(latLo, lonLo),
      LatLng(latLo, lonHi),
      LatLng(latHi, lonHi),
      LatLng(latHi, lonLo),
    ];
  }
}

/// Podział boku komórki przy próbkowaniu pokrycia.
///
/// Prostokąty `SCAN` są osiowane w lat/lon, a komórki w układzie linii startu,
/// więc na ogół nie pokrywają się co do brzegu i komórki bywają zeskanowane
/// częściowo. Liczenie dokładnego pola części wspólnej sumy obróconych
/// prostokątów z kwadratem jest niewspółmiernie kosztowne wobec tego, co z tego
/// wynika: komórka i tak liczy się jako znana dopiero przy pełnym pokryciu, a
/// ułamek służy wyłącznie do pokazania gradientu.
///
/// 4 x 4 daje rozdzielczość 1/16 i mieści maskę w jednym `Uint16`.
const int coverageSamples = 4;

const int _fullCoverage = 0xFFFF;

/// Siatka gotowa dla solvera plus to, co warto pokazać operatorowi.
class MappedField {
  MappedField({
    required this.field,
    required this.mapping,
    required this.frontEdge,
    required this.polygon,
    this.warnings = const [],
    this.correctedCorner,
    this.droppedMines = 0,
    Uint16List? coverage,
  }) : coverage = coverage ?? Uint16List(0);

  final GridField field;
  final FieldMapping mapping;

  /// Linia startu.
  final (LatLng, LatLng) frontEdge;

  /// Obrys po ewentualnej korekcie narożnika.
  final List<LatLng> polygon;

  final List<String> warnings;
  final int? correctedCorner;
  final int droppedMines;

  /// Maska próbek pokrycia na komórkę, indeks `y * cols + x`.
  ///
  /// Pusta lista, gdy nie podano żadnego prostokąta `SCAN` -- wtedy pokrycie
  /// jest nieznane, a nie zerowe, i UI powinno to rozróżnić.
  final Uint16List coverage;

  bool get hasCoverage => coverage.isNotEmpty;

  /// Ułamek komórki objęty skanem, od 0 do 1.
  double coverageOf(Cell cell) {
    if (coverage.isEmpty) return 0.0;
    final index = cell.y * field.cols + cell.x;
    if (index < 0 || index >= coverage.length) return 0.0;
    final bits = coverage[index];
    var count = 0;
    for (var i = 0; i < coverageSamples * coverageSamples; i++) {
      if (bits & (1 << i) != 0) count++;
    }
    return count / (coverageSamples * coverageSamples);
  }

  /// Ułamek pola objęty skanem, licząc tylko komórki wewnątrz obrysu.
  double get scannedFraction {
    if (coverage.isEmpty) return 0.0;
    var total = 0;
    var covered = 0.0;
    for (var y = 0; y < field.rows; y++) {
      for (var x = 0; x < field.cols; x++) {
        final cell = Cell(x, y);
        if (field.outside.contains(cell)) continue;
        total++;
        covered += coverageOf(cell);
      }
    }
    return total == 0 ? 0.0 : covered / total;
  }
}

bool _insideConvex(double u, double v, List<Vec2> quad) {
  var positive = false;
  var negative = false;
  for (var i = 0; i < quad.length; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % quad.length];
    final cross = (b.x - a.x) * (v - a.y) - (b.y - a.y) * (u - a.x);
    if (cross > 1e-12) positive = true;
    if (cross < -1e-12) negative = true;
    if (positive && negative) return false;
  }
  return true;
}

/// Próbkuje pokrycie komórek prostokątami `SCAN`.
///
/// Maski są sumowane bitowo, więc prostokąty mogą się dowolnie nakładać i
/// powtarzać -- dron nie musi pamiętać, co już wysłał.
Uint16List _sampleCoverage(FieldMapping mapping, List<ScanRegion> scans) {
  final coverage = Uint16List(mapping.cols * mapping.rows);
  const n = coverageSamples;

  for (final scan in scans) {
    final quad = [
      for (final corner in scan.corners)
        mapping.toUv(mapping.frame.toXy(corner)),
    ];

    var minU = double.infinity, maxU = -double.infinity;
    var minV = double.infinity, maxV = -double.infinity;
    for (final p in quad) {
      minU = math.min(minU, p.x);
      maxU = math.max(maxU, p.x);
      minV = math.min(minV, p.y);
      maxV = math.max(maxV, p.y);
    }

    final fromX = math.max(0, (minU / mapping.cellU).floor());
    final toX = math.min(mapping.cols - 1, (maxU / mapping.cellU).ceil());
    final fromY = math.max(0, (minV / mapping.cellV).floor());
    final toY = math.min(mapping.rows - 1, (maxV / mapping.cellV).ceil());

    for (var y = fromY; y <= toY; y++) {
      for (var x = fromX; x <= toX; x++) {
        final index = y * mapping.cols + x;
        if (coverage[index] == _fullCoverage) continue;

        final u0 = x * mapping.cellU;
        final v0 = y * mapping.cellV;
        final corners = [
          _insideConvex(u0, v0, quad),
          _insideConvex(u0 + mapping.cellU, v0, quad),
          _insideConvex(u0 + mapping.cellU, v0 + mapping.cellV, quad),
          _insideConvex(u0, v0 + mapping.cellV, quad),
        ];
        if (corners.every((c) => c)) {
          coverage[index] = _fullCoverage;
          continue;
        }
        if (corners.every((c) => !c) &&
            !_quadTouchesCell(quad, u0, v0, mapping)) {
          continue;
        }

        var bits = coverage[index];
        for (var j = 0; j < n; j++) {
          for (var i = 0; i < n; i++) {
            final bit = 1 << (j * n + i);
            if (bits & bit != 0) continue;
            final u = u0 + (i + 0.5) / n * mapping.cellU;
            final v = v0 + (j + 0.5) / n * mapping.cellV;
            if (_insideConvex(u, v, quad)) bits |= bit;
          }
        }
        coverage[index] = bits;
      }
    }
  }
  return coverage;
}

/// Czy prostokąt skanu w ogóle sięga komórki, gdy żaden jej róg nie jest w środku.
///
/// Bez tego wąski pas skanu przecinający komórkę na wylot zostałby pominięty:
/// jego rogi leżą poza komórką, a rogi komórki poza nim.
bool _quadTouchesCell(
  List<Vec2> quad,
  double u0,
  double v0,
  FieldMapping mapping,
) {
  final u1 = u0 + mapping.cellU;
  final v1 = v0 + mapping.cellV;
  for (final p in quad) {
    if (p.x >= u0 && p.x <= u1 && p.y >= v0 && p.y <= v1) return true;
  }
  final cell = [Vec2(u0, v0), Vec2(u1, v0), Vec2(u1, v1), Vec2(u0, v1)];
  for (var i = 0; i < quad.length; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % quad.length];
    for (var j = 0; j < 4; j++) {
      if (segmentsIntersect(a, b, cell[j], cell[(j + 1) % 4])) return true;
    }
  }
  return false;
}

class _CornerFix {
  const _CornerFix(this.polygon, this.corrected, this.warning);

  final List<Vec2> polygon;
  final int? corrected;
  final String? warning;
}

/// Podmienia jeden narożnik, jeśli pozostałe trzy trzymają kąt prosty.
///
/// Cztery ręcznie zmierzone punkty rzadko tworzą prostokąt. Gdy trzy z nich są
/// zgodne, a czwarty odstaje, to jest błąd pomiaru -- warto go poprawić, ale
/// trzeba o tym powiedzieć, a nie połknąć po cichu.
_CornerFix _fixCorner(List<Vec2> polygon) {
  if (polygon.length != 4) return _CornerFix(polygon, null, null);

  int? bestIndex;
  var bestResidual = double.infinity;
  Vec2? bestPoint;

  for (var i = 0; i < 4; i++) {
    final j = (i + 1) % 4;
    final k = (i + 2) % 4;
    final l = (i + 3) % 4;
    final a = polygon[j] - polygon[k];
    final b = polygon[l] - polygon[k];
    final na = a.length;
    final nb = b.length;
    if (na < 1e-6 || nb < 1e-6) continue;
    final residual = (a.x * b.x + a.y * b.y).abs() / (na * nb);
    if (residual < bestResidual) {
      bestIndex = i;
      bestResidual = residual;
      bestPoint = polygon[j] + polygon[l] - polygon[k];
    }
  }

  if (bestIndex == null || bestPoint == null) {
    return _CornerFix(polygon, null, null);
  }
  if (bestResidual > squarenessTolerance) {
    return _CornerFix(polygon, null, null);
  }

  final error = distanceBetween(polygon[bestIndex], bestPoint);
  if (error < cornerErrorMeters) return _CornerFix(polygon, null, null);

  if (error > maxCornerFixMeters) {
    return _CornerFix(
      polygon,
      null,
      'narożnik ${bestIndex + 1} odstaje o ${error.toStringAsFixed(1)} m od '
      'prostokąta wyznaczonego przez pozostałe trzy -- za dużo jak na błąd '
      'pomiaru, więc kształt pola zostaje bez zmian; sprawdź, czy to na '
      'pewno cztery narożniki tego samego pola',
    );
  }

  final fixed = List<Vec2>.from(polygon);
  fixed[bestIndex] = bestPoint;
  return _CornerFix(
    fixed,
    bestIndex,
    'narożnik ${bestIndex + 1} odstawał o ${error.toStringAsFixed(1)} m od '
    'prostokąta wyznaczonego przez pozostałe trzy -- poprawiony; sprawdź '
    'ten pomiar',
  );
}

/// Bok linii startu: KRÓTSZY bok, a spośród dwóch krótszych ten bliżej operatora.
///
/// Kolejność tych dwóch warunków jest cała treść tej funkcji. Przez pole idzie się
/// wzdłuż jego DŁUGIEJ osi -- spec.txt: 80 stóp szerokości na 300 stóp długości, a
/// ścieżka wchodzi z linii frontu i ma dojść do przeciwnego końca. Linią startu
/// może więc być tylko jeden z dwóch krótkich boków; operator decyduje jedynie,
/// KTÓRY z nich.
///
/// Wcześniej to była jedna reguła: "bok najbliższy obserwatorowi, awaryjnie
/// najkrótszy". Awaryjna gałąź była przypadkiem poprawna (na polu zawodowym
/// najkrótszy bok to właśnie krótki koniec), ale pierwsza ją nadpisywała: telefon
/// stojący przy DŁUGIM boku wybierał ten bok na linię startu, siatka kładła 40
/// kolumn na 300 stopach i 150 wierszy na 80 stopach, a ścieżka szła przez pole
/// w poprzek zamiast na wylot. Objawem były ostrzeżenia o rozmiarze komórki
/// (2.3 m zamiast 0.61 m) i jaśniejszy niebieski bok wzdłuż długiej krawędzi.
int _frontEdgeIndex(List<Vec2> polygon, Vec2? observer) {
  final n = polygon.length;
  final lengths = [
    for (var i = 0; i < n; i++)
      distanceBetween(polygon[i], polygon[(i + 1) % n]),
  ];

  // Kandydaci: boki nie dłuższe niż mediana. Na czworokącie zostawia to dwa
  // krótkie końce, także gdy pomiar jest niedokładny albo pole jest trapezem, bo
  // porównujemy z medianą, a nie z minimum.
  final sorted = [...lengths]..sort();
  final median = (sorted[(n - 1) ~/ 2] + sorted[n ~/ 2]) / 2.0;
  final candidates = [
    for (var i = 0; i < n; i++)
      if (lengths[i] <= median) i,
  ];
  final pool = candidates.isEmpty ? [for (var i = 0; i < n; i++) i] : candidates;

  var best = pool.first;
  var bestValue = double.infinity;
  for (final i in pool) {
    final a = polygon[i];
    final b = polygon[(i + 1) % n];
    final value = observer == null
        ? lengths[i]
        : pointSegmentDistance(observer, a, b);
    if (value < bestValue) {
      bestValue = value;
      best = i;
    }
  }
  return best;
}

/// Czy kwadrat komórki ma z wielokątem jakąkolwiek część wspólną.
bool _squareMeetsPolygon(
  double loU,
  double loV,
  double hiU,
  double hiV,
  List<Vec2> polygon,
) {
  final corners = [
    Vec2(loU, loV),
    Vec2(hiU, loV),
    Vec2(hiU, hiV),
    Vec2(loU, hiV),
  ];
  for (final c in corners) {
    if (pointInPolygon(c, polygon)) return true;
  }
  for (final p in polygon) {
    if (p.x >= loU && p.x <= hiU && p.y >= loV && p.y <= hiV) return true;
  }
  for (var i = 0; i < polygon.length; i++) {
    final a = polygon[i];
    final b = polygon[(i + 1) % polygon.length];
    for (var j = 0; j < 4; j++) {
      if (segmentsIntersect(a, b, corners[j], corners[(j + 1) % 4])) {
        return true;
      }
    }
  }
  return false;
}

/// Buduje siatkę z czterech zmierzonych narożników i pozycji min.
///
/// [grid] wymusza `(kolumny, wiersze)`. Domyślnie oficjalne 40x150 -- zmierzone
/// pole jest dzielone dokładnie na tyle komórek, więc path.txt trafia w siatkę
/// symulatora niezależnie od błędu pomiaru. `null` przełącza na komórki 2x2
/// stopy i wymiary wyliczone z pola.
MappedField mapField({
  required List<LatLng> corners,
  List<LatLng> mines = const [],
  List<ScanRegion> scans = const [],
  LatLng? observer,
  (int, int)? grid = officialGridSize,
  double cell = cellMeters,
  bool fixCorners = true,
}) {
  if (corners.length < 3) {
    throw ArgumentError('pole wymaga co najmniej 3 narożników');
  }

  final frame = LocalFrame.fromPoints(corners);
  var polygon = asCcw(frame.manyToXy(corners));

  final warnings = <String>[];
  int? corrected;
  if (fixCorners) {
    final fix = _fixCorner(polygon);
    polygon = fix.polygon;
    corrected = fix.corrected;
    if (fix.warning != null) warnings.add(fix.warning!);
  }

  final observerXy = observer == null ? null : frame.toXy(observer);
  final front = _frontEdgeIndex(polygon, observerXy);
  if (observerXy == null) {
    warnings.add(
      'brak pozycji obserwatora -- za linię startu przyjęto krótszy z dwóch końców pola; jeśli to zły koniec, ścieżka wyjdzie z przeciwnej strony',
    );
  }

  final a = polygon[front];
  final b = polygon[(front + 1) % polygon.length];
  final edgeLength = distanceBetween(a, b);
  if (edgeLength < 1e-6) {
    throw ArgumentError('linia startu ma zerową długość');
  }
  final axisX = Vec2((b.x - a.x) / edgeLength, (b.y - a.y) / edgeLength);
  final axisY = Vec2(-axisX.y, axisX.x);

  final probe = FieldMapping(
    frame: frame,
    origin: a,
    axisX: axisX,
    axisY: axisY,
    cols: 1,
    rows: 1,
    cellU: cell,
    cellV: cell,
  );
  final uv = [for (final p in polygon) probe.toUv(p)];
  var minU = double.infinity;
  var maxU = -double.infinity;
  var maxV = -double.infinity;
  for (final p in uv) {
    minU = math.min(minU, p.x);
    maxU = math.max(maxU, p.x);
    maxV = math.max(maxV, p.y);
  }
  final spanU = maxU - minU;
  if (spanU < 1e-6 || maxV < 1e-6) {
    throw ArgumentError(
      'pole jest zdegenerowane -- zerowa szerokość lub głębokość',
    );
  }

  final int cols;
  final int rows;
  final double cellU;
  final double cellV;
  if (grid == null) {
    cols = math.max(1, (spanU / cell).ceil());
    rows = math.max(1, (maxV / cell).ceil());
    cellU = cell;
    cellV = cell;
  } else {
    cols = grid.$1;
    rows = grid.$2;
    if (cols <= 0 || rows <= 0) {
      throw ArgumentError('wymuszona siatka musi mieć dodatnie wymiary');
    }
    cellU = spanU / cols;
    cellV = maxV / rows;
  }

  if (cols * rows > maxGridCells) {
    throw ArgumentError(
      'siatka ${cols}x$rows przekracza limit $maxGridCells komórek -- '
      'sprawdź współrzędne narożników',
    );
  }

  for (final (label, size) in [('w poprzek', cellU), ('w głąb', cellV)]) {
    if ((size - cellMeters).abs() / cellMeters > 0.05) {
      warnings.add(
        'komórka $label pola ma ${size.toStringAsFixed(2)} m zamiast '
        'nominalnych ${cellMeters.toStringAsFixed(2)} m -- zmierzone pole nie '
        'jest wielkości ${(cols * cellMeters / 0.3048).round()} x '
        '${(rows * cellMeters / 0.3048).round()} stóp',
      );
    }
  }

  final mapping = FieldMapping(
    frame: frame,
    origin: probe.toXy(Vec2(minU, 0.0)),
    axisX: axisX,
    axisY: axisY,
    cols: cols,
    rows: rows,
    cellU: cellU,
    cellV: cellV,
  );
  final polygonUv = [for (final p in polygon) mapping.toUv(p)];

  final outside = <Cell>{};
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      if (!_squareMeetsPolygon(
        x * cellU,
        y * cellV,
        (x + 1) * cellU,
        (y + 1) * cellV,
        polygonUv,
      )) {
        outside.add(Cell(x, y));
      }
    }
  }

  final coverage = scans.isEmpty
      ? Uint16List(0)
      : _sampleCoverage(mapping, scans);

  final mineCells = <Cell>{};
  var dropped = 0;
  for (final mine in mines) {
    final cellAt = mapping.cellOfLatLng(mine);
    if (cellAt == null || outside.contains(cellAt)) {
      dropped++;
      continue;
    }
    mineCells.add(cellAt);
  }
  if (dropped > 0) {
    warnings.add(
      '$dropped min poza obrysem pola -- pominięte przy budowie siatki',
    );
  }

  final unscanned = <Cell>{};
  if (scans.isNotEmpty) {
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        final cell = Cell(x, y);
        if (outside.contains(cell) || mineCells.contains(cell)) continue;
        if (coverage[y * cols + x] != _fullCoverage) unscanned.add(cell);
      }
    }
    if (unscanned.isNotEmpty) {
      final known = cols * rows - outside.length - unscanned.length;
      warnings.add(
        '${unscanned.length} komórek nieprzeskanowanych w całości '
        '(znanych: $known) -- ścieżka ich nie przetnie',
      );
    }
  }

  return MappedField(
    field: GridField(
      cols: cols,
      rows: rows,
      mines: mineCells,
      outside: outside,
      unscanned: unscanned,
    ),
    coverage: coverage,
    mapping: mapping,
    frontEdge: (frame.toLatLng(a), frame.toLatLng(b)),
    polygon: frame.manyToLatLng(polygon),
    warnings: warnings,
    correctedCorner: corrected,
    droppedMines: dropped,
  );
}
