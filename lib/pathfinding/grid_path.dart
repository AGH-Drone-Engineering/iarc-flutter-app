/// Siatka zawodowa IARC Mission 10: model pola, format path.txt, wynik.
///
/// Port `minefield_path/grid.py`. Referencyjna implementacja w Pythonie jest
/// sprawdzona przeglądem zupełnym na małych polach, a zgodności portu pilnują
/// złote dane w `test/fixtures/grid_fixtures.json`.
///
/// Semantyka kroku: komenda `S` stawia idącego na linii startu *poniżej*
/// wiersza 0, a każdy krok wchodzi na jedną nową komórkę. Dlatego `S,0,0` +
/// `U,150` odwiedza wiersze 0..149 w 150 krokach, co daje L = 300 stóp --
/// dokładnie fizyczną długość pola.
library;

import 'dart:math' as math;

/// Bok komórki w stopach.
const double cellFeet = 2.0;

const double cellMeters = cellFeet * 0.3048;

const int officialCols = 40;
const int officialRows = 150;

/// Twardy limit symulatora: 20 komórek strefy zielonej na każdą stronę.
///
/// Bez niego wzór nie ma maksimum względem G. W = 2*(1+2G) rośnie liniowo bez
/// końca, a B nasyca się, gdy strefa obejmie całe pole -- przy ścieżce pod
/// ścianą już od G ~ 40. Limit zamyka tę lukę: największe dopuszczalne W to
/// 2*(1 + 2*20) = 82 stopy.
const int maxGreenSquares = 20;

const double maxWidthFeet = cellFeet * (1 + 2 * maxGreenSquares);

/// Komórka siatki. `x` rośnie w poprzek pola, `y` w głąb, od linii startu.
class Cell {
  const Cell(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Cell && other.x == x && other.y == y);

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => '($x,$y)';
}

/// Kształt strefy zielonej wokół ścieżki.
///
/// [manhattan] -- komórka wchodzi do strefy, gdy `|dx| + |dy| <= G` od
/// *którejkolwiek* komórki ścieżki, czyli romb. To zachowanie symulatora,
/// sprawdzone znak po znaku na dwóch jego zrzutach (`try.txt`, `sevenwide.txt`;
/// testy w `minefield_path/tests/test_zone_shape.py`).
///
/// Odległość euklidesowa daje to samo dla G <= 2 i długo wyglądała na właściwą,
/// ale przy G=6 się rozjeżdża: zrzut ma prostą krawędź pod 45 stopni, a koło
/// dałoby łuk.
///
/// [perpendicular] -- G komórek prostopadle do każdego prostego odcinka, bez
/// wypełniania narożników. Pierwsze odczytanie spec.txt, obalone przez zrzut.
///
/// [square] -- dylatacja Czebyszewa. Zawyża B, bo bierze narożniki, których
/// symulator nie liczy.
enum GreenZoneShape {
  manhattan('manhattan'),
  perpendicular('perpendicular'),
  square('square');

  const GreenZoneShape(this.wireName);

  final String wireName;

  static GreenZoneShape byName(String name) =>
      values.firstWhere((v) => v.wireName == name);
}

const Map<String, Cell> _directions = {
  'U': Cell(0, 1),
  'D': Cell(0, -1),
  'L': Cell(-1, 0),
  'R': Cell(1, 0),
};

/// Jedna komenda ruchu: kierunek i liczba kroków.
class Move {
  const Move(this.direction, this.count);

  final String direction;
  final int count;

  @override
  bool operator ==(Object other) =>
      other is Move && other.direction == direction && other.count == count;

  @override
  int get hashCode => Object.hash(direction, count);
}

/// Pole zrasteryzowane do komórek 2x2 stopy.
class GridField {
  GridField({
    required this.cols,
    required this.rows,
    Set<Cell>? mines,
    Set<Cell>? outside,
    Set<Cell>? unscanned,
  }) : mines = mines ?? const {},
       outside = outside ?? const {},
       unscanned = unscanned ?? const {} {
    if (cols <= 0 || rows <= 0) {
      throw ArgumentError('pole musi mieć dodatnie wymiary');
    }
  }

  /// Oficjalne pole z Huntsville: 40 x 150 komórek (80 x 300 stóp).
  factory GridField.official({Set<Cell>? mines}) =>
      GridField(cols: officialCols, rows: officialRows, mines: mines);

  final int cols;
  final int rows;
  final Set<Cell> mines;

  /// Komórki poza obrysem pola -- nieprzejezdne, ale bez kary B, bo miny tam
  /// nie występują.
  final Set<Cell> outside;

  /// Komórki w polu, których nikt nie przeskanował w całości.
  ///
  /// „Nie ma tu miny" i „nikt tu nie patrzył" to dwie różne rzeczy. Komórka
  /// liczy się jako znana dopiero, gdy pokrywa ją w całości któryś prostokąt
  /// `SCAN` -- albo gdy znaleziono w niej minę, bo wtedy i tak wiemy, co tam
  /// jest. Reszta trafia tutaj i jest nieprzejezdna dla niebieskiej linii.
  ///
  /// Do B *nie* wchodzi. Miny w takiej komórce mogą być, ale ich nie
  /// potwierdzono, więc doliczanie ich do wyniku byłoby zgadywaniem. Scorer
  /// raportuje je osobno jako [Score.unscannedInZone].
  final Set<Cell> unscanned;

  bool inBounds(Cell cell) =>
      cell.x >= 0 && cell.x < cols && cell.y >= 0 && cell.y < rows;

  /// Czy komórka leży w obrysie pola, a nie tylko w prostokącie siatki.
  bool inside(Cell cell) => inBounds(cell) && !outside.contains(cell);

  /// Komórki, na które niebieska ścieżka nie może wejść.
  ///
  /// To [outside] plus miny rozdmuchane o [inflation] komórek. Rozdmuchanie
  /// jest zabezpieczeniem przed błędem GPS: komórka ma 0.61 m, a namiar drona
  /// jest metrowy, więc mina przypisana o jedną komórkę za daleko postawiłaby
  /// ścieżkę wprost na minie -- czyli wynik 0.
  Set<Cell> blocked({int inflation = 0}) {
    final out = <Cell>{...outside, ...unscanned};
    for (final mine in mines) {
      for (var dx = -inflation; dx <= inflation; dx++) {
        for (var dy = -inflation; dy <= inflation; dy++) {
          out.add(Cell(mine.x + dx, mine.y + dy));
        }
      }
    }
    return out;
  }
}

/// Ścieżka w formacie path.txt.
class GridPath {
  const GridPath({
    required this.startCol,
    required this.green,
    this.moves = const [],
  });

  /// Wczytuje path.txt. Puste linie i komentarze `#` są pomijane.
  factory GridPath.parse(String text) {
    int? startCol;
    int? green;
    final moves = <Move>[];

    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].split('#').first.trim();
      if (line.isEmpty) continue;
      final parts = line.split(',').map((p) => p.trim()).toList();
      final head = parts.first.toUpperCase();
      final lineNo = i + 1;

      if (head == 'S') {
        if (startCol != null) {
          throw FormatException('linia $lineNo: druga komenda S');
        }
        if (moves.isNotEmpty) {
          throw FormatException('linia $lineNo: S musi być pierwsza');
        }
        if (parts.length != 3) {
          throw FormatException('linia $lineNo: S wymaga 2 argumentów');
        }
        startCol = int.parse(parts[1]);
        green = int.parse(parts[2]);
        if (green < 0) {
          throw FormatException(
            'linia $lineNo: szerokość strefy zielonej nie może być ujemna',
          );
        }
      } else if (_directions.containsKey(head)) {
        if (startCol == null) {
          throw FormatException('linia $lineNo: ruch przed komendą S');
        }
        if (parts.length != 2) {
          throw FormatException('linia $lineNo: $head wymaga 1 argumentu');
        }
        final count = int.parse(parts[1]);
        if (count <= 0) {
          throw FormatException('linia $lineNo: liczba kroków musi być > 0');
        }
        moves.add(Move(head, count));
      } else {
        throw FormatException('linia $lineNo: nieznana komenda ${parts.first}');
      }
    }

    if (startCol == null || green == null) {
      throw const FormatException('brak komendy S');
    }
    return GridPath(startCol: startCol, green: green, moves: moves);
  }

  /// Odtwarza komendy z ciągu komórek (odwrotność [cells]).
  factory GridPath.fromCells(List<Cell> cells, int green) {
    if (cells.isEmpty) throw ArgumentError('pusta ścieżka');
    final moves = <Move>[];
    var prev = Cell(cells.first.x, cells.first.y - 1);
    for (final cell in cells) {
      final dx = cell.x - prev.x;
      final dy = cell.y - prev.y;
      final direction = _directions.entries
          .where((e) => e.value.x == dx && e.value.y == dy)
          .map((e) => e.key)
          .firstOrNull;
      if (direction == null) {
        throw ArgumentError('komórki $prev -> $cell nie sąsiadują');
      }
      if (moves.isNotEmpty && moves.last.direction == direction) {
        moves[moves.length - 1] = Move(direction, moves.last.count + 1);
      } else {
        moves.add(Move(direction, 1));
      }
      prev = cell;
    }
    return GridPath(startCol: cells.first.x, green: green, moves: moves);
  }

  /// Kolumna wejścia na linii startu (komenda `S`).
  final int startCol;

  /// G -- szerokość strefy zielonej w komórkach na każdą stronę.
  final int green;

  final List<Move> moves;

  /// Suma kroków, czyli S ze wzoru na wynik (L = 2*S stóp).
  int get steps => moves.fold(0, (sum, m) => sum + m.count);

  /// Komórki odwiedzone przez niebieską ścieżkę, w kolejności wejścia.
  ///
  /// Start jest wirtualny, tuż poniżej wiersza 0, więc pierwszy krok `U`
  /// wchodzi na `(startCol, 0)`.
  List<Cell> cells() {
    var x = startCol;
    var y = -1;
    final out = <Cell>[];
    for (final move in moves) {
      final delta = _directions[move.direction]!;
      for (var i = 0; i < move.count; i++) {
        x += delta.x;
        y += delta.y;
        out.add(Cell(x, y));
      }
    }
    return out;
  }

  /// Zapis do path.txt. Kolejne ruchy w tę samą stronę są scalane.
  String toText() {
    final merged = <Move>[];
    for (final move in moves) {
      if (merged.isNotEmpty && merged.last.direction == move.direction) {
        merged[merged.length - 1] = Move(
          move.direction,
          merged.last.count + move.count,
        );
      } else {
        merged.add(move);
      }
    }
    final buffer = StringBuffer('S,$startCol,$green\n');
    for (final move in merged) {
      buffer.write('${move.direction},${move.count}\n');
    }
    return buffer.toString();
  }
}

/// Maksymalne proste odcinki ścieżki, jako pary (początek, koniec).
///
/// Komórka na zakręcie należy do obu sąsiednich odcinków -- to ona decyduje
/// o kształcie strefy zielonej w narożniku.
List<(Cell, Cell)> pathRuns(List<Cell> cells) {
  if (cells.isEmpty) return const [];
  if (cells.length == 1) return [(cells.first, cells.first)];

  final out = <(Cell, Cell)>[];
  var start = 0;
  var dx = cells[1].x - cells[0].x;
  var dy = cells[1].y - cells[0].y;

  for (var i = 1; i < cells.length - 1; i++) {
    final nx = cells[i + 1].x - cells[i].x;
    final ny = cells[i + 1].y - cells[i].y;
    if (nx != dx || ny != dy) {
      out.add((cells[start], cells[i]));
      start = i;
      dx = nx;
      dy = ny;
    }
  }
  out.add((cells[start], cells.last));
  return out;
}

/// Komórki strefy zielonej, bez komórek samej ścieżki.
///
/// Strefa nie jest przycinana do pola: miny i tak istnieją tylko wewnątrz, więc
/// dla B to bez znaczenia, a wyjście poza pole jest tu istotne -- W zależy
/// wyłącznie od zadeklarowanego G, więc trzymanie się brzegu daje pełną
/// szerokość przy połowie ekspozycji na miny.
Set<Cell> greenZoneCells(
  List<Cell> cells,
  int green, {
  GreenZoneShape shape = GreenZoneShape.manhattan,
}) {
  if (green <= 0 || cells.isEmpty) return <Cell>{};

  final zone = <Cell>{};
  if (shape == GreenZoneShape.manhattan) {
    for (final cell in cells) {
      for (var dy = -green; dy <= green; dy++) {
        final reach = green - dy.abs();
        for (var dx = -reach; dx <= reach; dx++) {
          zone.add(Cell(cell.x + dx, cell.y + dy));
        }
      }
    }
  } else if (shape == GreenZoneShape.square) {
    for (final cell in cells) {
      for (var dx = -green; dx <= green; dx++) {
        for (var dy = -green; dy <= green; dy++) {
          zone.add(Cell(cell.x + dx, cell.y + dy));
        }
      }
    }
  } else {
    for (final (a, b) in pathRuns(cells)) {
      if (a.x == b.x) {
        for (var y = math.min(a.y, b.y); y <= math.max(a.y, b.y); y++) {
          for (var dx = -green; dx <= green; dx++) {
            zone.add(Cell(a.x + dx, y));
          }
        }
      } else {
        for (var x = math.min(a.x, b.x); x <= math.max(a.x, b.x); x++) {
          for (var dy = -green; dy <= green; dy++) {
            zone.add(Cell(x, a.y + dy));
          }
        }
      }
    }
  }

  zone.removeAll(cells);
  return zone;
}

/// Zasięg strefy w bok, w wierszu oddalonym o [dy] od komórki ścieżki.
///
/// Zwraca -1, gdy w tym wierszu strefa nie sięga wcale. Dzięki temu pokrycie
/// miny sprowadza się do przecięcia dwóch przedziałów, niezależnie od kształtu.
int zoneReach(int green, int dy, GreenZoneShape shape) {
  if (dy.abs() > green) return -1;
  switch (shape) {
    case GreenZoneShape.square:
      return green;
    case GreenZoneShape.perpendicular:
      return dy == 0 ? green : 0;
    case GreenZoneShape.manhattan:
      return green - dy.abs();
  }
}

/// Czy prosty odcinek `a..b` ścieżki wciąga minę do strefy zielonej.
bool _runCoversMine(
  Cell a,
  Cell b,
  Cell mine,
  int green,
  GreenZoneShape shape,
) {
  final loX = math.min(a.x, b.x);
  final hiX = math.max(a.x, b.x);
  final loY = math.min(a.y, b.y);
  final hiY = math.max(a.y, b.y);

  if (shape == GreenZoneShape.square) {
    return mine.x >= loX - green &&
        mine.x <= hiX + green &&
        mine.y >= loY - green &&
        mine.y <= hiY + green;
  }
  if (a.x == b.x) {
    return mine.x >= loX - green &&
        mine.x <= hiX + green &&
        mine.y >= loY &&
        mine.y <= hiY;
  }
  return mine.x >= loX &&
      mine.x <= hiX &&
      mine.y >= loY - green &&
      mine.y <= hiY + green;
}

/// B -- liczba min w strefie zielonej, bez materializowania samej strefy.
///
/// [greenZoneCells] alokuje zbiór rzędu `wiersze * (2G+1)` komórek, co przy
/// tysiącach wywołań z wspinaczki kosztuje więcej niż samo liczenie. Tu
/// przechodzimy po minach i sprawdzamy je względem prostych odcinków ścieżki,
/// więc koszt to `miny * odcinki` bez żadnej alokacji.
int missedMineCount(
  GridField field,
  List<Cell> cells,
  int green, {
  GreenZoneShape shape = GreenZoneShape.manhattan,
}) {
  if (green <= 0 || cells.isEmpty || field.mines.isEmpty) return 0;
  final onPath = cells.toSet();
  var missed = 0;

  if (shape == GreenZoneShape.manhattan) {
    for (final mine in field.mines) {
      if (onPath.contains(mine)) continue;
      for (final cell in cells) {
        if ((cell.x - mine.x).abs() + (cell.y - mine.y).abs() <= green) {
          missed++;
          break;
        }
      }
    }
    return missed;
  }

  final runs = pathRuns(cells);
  for (final mine in field.mines) {
    if (onPath.contains(mine)) continue;
    for (final (a, b) in runs) {
      if (_runCoversMine(a, b, mine, green, shape)) {
        missed++;
        break;
      }
    }
  }
  return missed;
}

/// Człony wzoru niezależne od ścieżki.
class ScoreParams {
  const ScoreParams({
    this.scanMinutes = 0.0,
    this.overweightOz = 0.0,
    this.shape = GreenZoneShape.manhattan,
    this.mineInflation = 1,
  });

  /// A -- minuty skanowania pola.
  final double scanMinutes;

  /// N -- uncje ponad limit 1 funta na dron.
  final double overweightOz;

  final GreenZoneShape shape;

  /// Promień zakazu wokół miny dla niebieskiej ścieżki.
  final int mineInflation;

  /// Mianownik `1 + 7*A + 100*N`.
  double get penalty => 1.0 + 7.0 * scanMinutes + 100.0 * overweightOz;

  ScoreParams copyWith({
    double? scanMinutes,
    double? overweightOz,
    GreenZoneShape? shape,
    int? mineInflation,
  }) => ScoreParams(
    scanMinutes: scanMinutes ?? this.scanMinutes,
    overweightOz: overweightOz ?? this.overweightOz,
    shape: shape ?? this.shape,
    mineInflation: mineInflation ?? this.mineInflation,
  );
}

/// Wynik ścieżki policzony dokładnie.
class Score {
  const Score({
    required this.value,
    required this.valid,
    required this.reason,
    required this.steps,
    required this.green,
    required this.missed,
    required this.minesOnPath,
    this.unscannedInZone = 0,
    this.unscannedOnPath = 0,
    required this.lengthFt,
    required this.widthFt,
    this.zoneCells = const {},
    this.pathCells = const [],
  });

  final double value;
  final bool valid;
  final String reason;
  final int steps;
  final int green;

  /// B -- miny w strefie zielonej.
  final int missed;

  /// Miny na niebieskiej linii. Każda zeruje wynik.
  final int minesOnPath;

  /// Komórki strefy zielonej, których nikt nie przeskanował.
  ///
  /// Nie wchodzą do B i nie zmieniają wyniku -- to nie są potwierdzone miny.
  /// Są za to miarą tego, ile z tego wyniku jest obietnicą: przy dużej
  /// wartości „ile punktów" znaczy tylko „tyle, o ile teren jest czysty".
  final int unscannedInZone;

  /// Komórki niebieskiej linii, których nikt nie przeskanował.
  ///
  /// Solver ich nie dopuszcza, więc niezerowa wartość oznacza ścieżkę wczytaną
  /// z zewnątrz albo policzoną na starszym pokryciu.
  final int unscannedOnPath;

  final double lengthFt;
  final double widthFt;
  final Set<Cell> zoneCells;
  final List<Cell> pathCells;
}

/// Wynik wg spec.txt: `150000 * W / ((1+B) * L * (1 + 7A + 100N))`.
///
/// Ścieżka niepoprawna strukturalnie (poza polem, z nawrotem, nie dochodząca do
/// mety) dostaje 0 wraz z powodem. Mina na niebieskiej linii też daje 0, ale
/// ścieżka pozostaje "poprawna" -- to rozróżnienie widać w UI.
Score scoreGridPath(
  GridField field,
  GridPath path, [
  ScoreParams params = const ScoreParams(),
]) {
  final cells = path.cells();
  final steps = path.steps;
  final lengthFt = cellFeet * steps;
  final widthFt = cellFeet * (1 + 2 * path.green);

  final zone = greenZoneCells(cells, path.green, shape: params.shape);
  var onPath = 0;
  var unscannedOnPath = 0;
  for (final cell in cells) {
    if (field.mines.contains(cell)) onPath++;
    if (field.unscanned.contains(cell)) unscannedOnPath++;
  }
  var missed = 0;
  var unscannedInZone = 0;
  for (final cell in zone) {
    if (field.mines.contains(cell)) missed++;
    if (field.unscanned.contains(cell)) unscannedInZone++;
  }

  Score fail(String reason) => Score(
    value: 0.0,
    valid: false,
    reason: reason,
    steps: steps,
    green: path.green,
    missed: missed,
    minesOnPath: onPath,
    unscannedInZone: unscannedInZone,
    unscannedOnPath: unscannedOnPath,
    lengthFt: lengthFt,
    widthFt: widthFt,
    zoneCells: zone,
    pathCells: cells,
  );

  if (cells.isEmpty) return fail('ścieżka nie ma żadnego kroku');
  if (path.green < 0) return fail('ujemna szerokość strefy zielonej');
  if (path.green > maxGreenSquares) {
    return fail(
      'G = ${path.green} przekracza limit symulatora $maxGreenSquares '
      '(najszersza dopuszczalna ścieżka to ${maxWidthFeet.toStringAsFixed(0)} '
      'stóp)',
    );
  }
  if (path.startCol < 0 || path.startCol >= field.cols) {
    return fail('kolumna startowa ${path.startCol} poza polem');
  }
  if (cells.toSet().length != cells.length) {
    return fail('ścieżka odwiedza tę samą komórkę dwa razy');
  }
  for (final cell in cells) {
    if (!field.inBounds(cell)) {
      return fail('ścieżka wychodzi poza siatkę w $cell');
    }
    if (field.outside.contains(cell)) {
      return fail('ścieżka wychodzi poza obrys pola w $cell');
    }
    if (field.unscanned.contains(cell)) {
      return fail('ścieżka przechodzi przez nieprzeskanowany teren w $cell');
    }
  }

  final last = cells.last;
  if (field.inside(Cell(last.x, last.y + 1))) {
    return fail('ścieżka nie dochodzi do mety, kończy się w $last');
  }

  var value = 0.0;
  var reason = 'ok';
  if (onPath > 0) {
    reason = '$onPath min na niebieskiej linii -- wynik 0';
  } else {
    value = 150000.0 * widthFt / ((1 + missed) * lengthFt * params.penalty);
  }

  return Score(
    value: value,
    valid: true,
    reason: reason,
    steps: steps,
    green: path.green,
    missed: missed,
    minesOnPath: onPath,
    unscannedInZone: unscannedInZone,
    unscannedOnPath: unscannedOnPath,
    lengthFt: lengthFt,
    widthFt: widthFt,
    zoneCells: zone,
    pathCells: cells,
  );
}
