/// Solver siatki zawodowej: przebieg czysty + DP z wymiarem B + wspinaczka.
///
/// Port `minefield_path/gridsolver.py`. Maksymalizujemy
/// `f = (1 + 2G) / ((1 + B) * kroki)` -- to jest wynik z spec.txt po skróceniu
/// stałych. To *nie* jest kryterium maximin z solvera Woronoja: wzór płaci za
/// szerokość na tyle dobrze, że opłaca się przyjąć minę w strefie zielonej
/// (G 0->1 potraja W, a pierwsza pominięta mina tylko połowi wynik), a długość
/// wchodzi wprost, nie jako rozstrzygnięcie remisu.
///
/// Dwa przebiegi:
///
/// 1. **czysty (B = 0)** -- dokładny i tani. Zbiór komórek zakazanych da się
///    wypisać wprost (patrz [zeroMissedBlocked]), więc zostaje zwykłe
///    minimalizowanie kroków, bez wymiaru B i bez przybliżeń.
/// 2. **z wymiarem B** -- przybliżony, dokłada przypadki, w których opłaca się
///    zebrać minę. Na dużym polu wygrywa rzadko, ale na płytkim regularnie.
///
/// Wynik zwracany na zewnątrz zawsze pochodzi z [scoreGridPath], nigdy z
/// oszacowania DP: obciążanie miny przy *włączeniu* pokrycia zakłada spójność
/// wierszy pokrywających, a to potrafi pęknąć przy zygzaku. Błąd idzie w
/// bezpieczną stronę (DP zawyża B), ale i tak liczy się tylko wynik dokładny.
///
/// Ścieżki są y-monotoniczne (U/L/R). Ograniczenie jest bezpieczne, ale *nie*
/// dlatego, że zamknięty wiersz blokuje wszystko: monotoniczna ścieżka może nie
/// istnieć także wtedy, gdy wolne odcinki kolejnych wierszy się nie zazębiają.
/// Gdy DP nic nie znajdzie, sprawdzamy 4-spójność wolnych komórek i mówimy
/// wprost, który z tych dwóch przypadków zaszedł.
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'grid_path.dart';

const double _inf = double.infinity;

/// Parametry przeszukiwania.
class SolverConfig {
  const SolverConfig({
    this.maxGreen = maxGreenSquares,
    this.maxLateral = 8,
    this.maxMissed = 24,
    this.localSearchRounds = 40,
    this.refine = true,
  });

  /// Największe rozważane G. Domyślnie limit symulatora (82 stopy szerokości).
  ///
  /// Ten limit jest tym, co w ogóle czyni zadanie dobrze postawionym: bez niego
  /// W rośnie liniowo bez końca, a B nasyca się po objęciu całego pola, więc
  /// optimum leżałoby w nieskończoności.
  final int maxGreen;

  /// Największy skok w bok w obrębie jednego wiersza.
  ///
  /// Nie ogranicza sumarycznego przesunięcia -- ten sam zjazd rozłożony na
  /// kilka wierszy kosztuje tyle samo kroków.
  final int maxLateral;

  /// Twardy limit B, zanim pojawi się pierwszy wynik odniesienia.
  final int maxMissed;

  /// Przebiegi wspinaczki po dokładnym wyniku.
  final int localSearchRounds;

  /// Czy po przebiegu czystym puszczać jeszcze DP z wymiarem B.
  ///
  /// Potrzebne. Sam przebieg czysty rozmija się z przeglądem zupełnym w 22 na
  /// 60 losowych plansz 5x5 -- na polach płytkich dopłacenie miną często
  /// wygrywa. Wyłączenie daje ~4x szybszy przebieg kosztem jakości.
  final bool refine;
}

/// Wynik solvera.
class GridSolution {
  const GridSolution({
    required this.found,
    required this.reason,
    this.path,
    this.result,
    this.perGreen = const {},
    this.missedCap = const {},
    this.timingsMs = const {},
  });

  final bool found;
  final String reason;
  final GridPath? path;
  final Score? result;

  /// Najlepszy dokładny wynik znaleziony dla danego G -- pokazuje kompromis
  /// szerokość/miny.
  final Map<int, double> perGreen;

  /// Limit B użyty przy każdym G. Zapisany, żeby obcięte przeszukanie nie
  /// wyglądało jak wyczerpujące.
  final Map<int, int> missedCap;

  final Map<String, double> timingsMs;
}

/// Ciąg kolumn wejścia w kolejne wiersze -> komórki niebieskiej ścieżki.
List<Cell> columnsToCells(List<int> columns) {
  final cells = <Cell>[];
  for (var row = 0; row < columns.length; row++) {
    final col = columns[row];
    cells.add(Cell(col, row));
    if (row + 1 < columns.length) {
      final next = columns[row + 1];
      final step = next > col ? 1 : -1;
      for (var x = col + step; x != next + step; x += step) {
        cells.add(Cell(x, row));
      }
    }
  }
  return cells;
}

/// Ciąg kolumn -> ścieżka w formacie path.txt.
GridPath columnsToPath(List<int> columns, int green) =>
    GridPath.fromCells(columnsToCells(columns), green);

/// Komórki, których ścieżka musi unikać, żeby B wyszło dokładnie 0.
///
/// Strefa jest symetryczna, więc warunek odwraca się wprost: mina trafia do
/// strefy dokładnie wtedy, gdy ścieżka wejdzie w jej strefę. Blokadą jest więc
/// ten sam kształt, tylko postawiony wokół miny -- romb dla strefy rombowej,
/// kwadrat dla [GreenZoneShape.square].
///
/// Do tego dochodzi rozdmuchanie miny o `mineInflation`, chroniące przed błędem
/// GPS niezależnie od G.
Set<Cell> zeroMissedBlocked(GridField field, int green, ScoreParams params) {
  final out = <Cell>{...field.outside};
  final infl = params.mineInflation;
  for (final mine in field.mines) {
    for (var dx = -infl; dx <= infl; dx++) {
      for (var dy = -infl; dy <= infl; dy++) {
        out.add(Cell(mine.x + dx, mine.y + dy));
      }
    }
    for (var dy = -green; dy <= green; dy++) {
      final reach = zoneReach(green, dy, params.shape);
      if (reach < 0) continue;
      for (var dx = -reach; dx <= reach; dx++) {
        out.add(Cell(mine.x + dx, mine.y + dy));
      }
    }
  }
  return out;
}

/// Zablokowane komórki jako tablica bitów, indeks `y * cols + x`.
Uint8List _blockedGrid(GridField field, Set<Cell> blocked) {
  final grid = Uint8List(field.cols * field.rows);
  for (final cell in blocked) {
    if (field.inBounds(cell)) grid[cell.y * field.cols + cell.x] = 1;
  }
  return grid;
}

/// Prefiksowa liczba zablokowanych komórek w wierszu -- test odcinka w O(1).
Int32List _blockedPrefix(GridField field, Uint8List grid) {
  final stride = field.cols + 1;
  final prefix = Int32List(field.rows * stride);
  for (var y = 0; y < field.rows; y++) {
    final base = y * stride;
    for (var x = 0; x < field.cols; x++) {
      prefix[base + x + 1] = prefix[base + x] + grid[y * field.cols + x];
    }
  }
  return prefix;
}

bool _spanFree(Int32List prefix, int stride, int row, int a, int b) {
  final lo = a <= b ? a : b;
  final hi = a <= b ? b : a;
  final base = row * stride;
  return prefix[base + hi + 1] - prefix[base + lo] == 0;
}

/// Najkrótsza ścieżka monotoniczna omijająca [blocked]. Dokładna.
///
/// Bez wymiaru B i bez przybliżeń -- przy ustalonym zbiorze zablokowanych
/// komórek zostaje zwykłe minimalizowanie kroków. `rows * cols^2` operacji.
List<int>? minStepsColumns(GridField field, Set<Cell> blocked) {
  final cols = field.cols;
  final rows = field.rows;
  final grid = _blockedGrid(field, blocked);
  final prefix = _blockedPrefix(field, grid);
  final stride = cols + 1;

  var cost = List<double>.generate(cols, (x) => grid[x] == 0 ? 0.0 : _inf);
  final parents = <Int32List>[];

  for (var row = 0; row < rows - 1; row++) {
    final next = List<double>.filled(cols, _inf);
    final chosen = Int32List(cols)..fillRange(0, cols, -1);
    for (var b = 0; b < cols; b++) {
      if (grid[(row + 1) * cols + b] != 0) continue;
      for (var a = 0; a < cols; a++) {
        if (cost[a] == _inf || !_spanFree(prefix, stride, row, a, b)) continue;
        final total = cost[a] + (b - a).abs();
        if (total < next[b]) {
          next[b] = total;
          chosen[b] = a;
        }
      }
    }
    cost = next;
    parents.add(chosen);
    if (cost.every((v) => v == _inf)) return null;
  }

  var end = 0;
  for (var x = 1; x < cols; x++) {
    if (cost[x] < cost[end]) end = x;
  }
  if (cost[end] == _inf) return null;

  final columns = <int>[end];
  for (var row = rows - 2; row >= 0; row--) {
    end = parents[row][end];
    columns.add(end);
  }
  return columns.reversed.toList();
}

/// Czy wolne komórki łączą linię startu z metą w sensie 4-spójności.
bool freeCellsConnect(GridField field, Set<Cell> blocked) {
  final grid = _blockedGrid(field, blocked);
  final seen = Uint8List(field.cols * field.rows);
  final queue = Queue<int>();

  for (var x = 0; x < field.cols; x++) {
    if (grid[x] == 0) {
      seen[x] = 1;
      queue.add(x);
    }
  }

  while (queue.isNotEmpty) {
    final index = queue.removeFirst();
    final x = index % field.cols;
    final y = index ~/ field.cols;
    if (y == field.rows - 1) return true;
    for (final (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]) {
      if (nx < 0 || nx >= field.cols || ny < 0 || ny >= field.rows) continue;
      final n = ny * field.cols + nx;
      if (grid[n] != 0 || seen[n] != 0) continue;
      seen[n] = 1;
      queue.add(n);
    }
  }
  return false;
}

int _popcount32(int v) {
  v -= (v >> 1) & 0x55555555;
  v = (v & 0x33333333) + ((v >> 2) & 0x33333333);
  v = (v + (v >> 4)) & 0x0F0F0F0F;
  return ((v * 0x01010101) >> 24) & 0x3F;
}

/// Maski bitowe min pokrytych w danym wierszu przy odcinku `[lo, hi]`.
///
/// Bit `i` odpowiada `i`-tej minie w ustalonym porządku, dzięki czemu "nowo
/// obciążone" to jedna operacja: `popcount(cur & ~prev)`.
///
/// Dla wiersza własnego miny obowiązuje odcinek rozszerzony o G (pionowe
/// odcinki ścieżki plus poziomy w tym wierszu sklejają się w `[lo-G, hi+G]`).
/// Dla pozostałych wierszy okna liczy się goły odcinek poziomy.
class _CoverMasks {
  _CoverMasks(GridField field, int green, int maxLateral, GreenZoneShape shape)
    : _cols = field.cols,
      _widths = maxLateral + 1,
      _words = ((field.mines.length + 31) ~/ 32).clamp(1, 1 << 30) {
    final mines = field.mines.toList()
      ..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
    final byRow = List.generate(field.rows, (_) => <(int, int)>[]);
    for (var i = 0; i < mines.length; i++) {
      final mine = mines[i];
      if (mine.y >= 0 && mine.y < field.rows) byRow[mine.y].add((mine.x, i));
    }

    _table = Uint32List(field.rows * _cols * _widths * _words);
    for (var row = 0; row < field.rows; row++) {
      final window = <(int, int, int)>[];
      final from = math.max(0, row - green);
      final to = math.min(field.rows - 1, row + green);
      for (var other = from; other <= to; other++) {
        final reach = zoneReach(green, row - other, shape);
        if (reach < 0) continue;
        for (final (mx, i) in byRow[other]) {
          window.add((mx, i, reach));
        }
      }
      for (var lo = 0; lo < _cols; lo++) {
        for (var w = 0; w < _widths; w++) {
          final hi = lo + w;
          if (hi >= _cols) break;
          final base = _base(row, lo, w);
          for (final (mx, i, reach) in window) {
            if (lo - reach <= mx && mx <= hi + reach) {
              _table[base + (i >> 5)] |= 1 << (i & 31);
            }
          }
        }
      }
    }
  }

  final int _cols;
  final int _widths;
  final int _words;
  late final Uint32List _table;

  int _base(int row, int lo, int width) =>
      (((row * _cols) + lo) * _widths + width) * _words;

  /// Liczba min pokrytych w `row` przy odcinku od `a` do `b`, których nie
  /// pokrywał odcinek `prev` w wierszu `prevRow`.
  int newlyCharged(int row, int a, int b, int prevRow, int pa, int pb) {
    final lo = a <= b ? a : b;
    final width = (b - a).abs();
    final base = _base(row, lo, width);
    if (prevRow < 0) {
      var total = 0;
      for (var w = 0; w < _words; w++) {
        total += _popcount32(_table[base + w]);
      }
      return total;
    }
    final plo = pa <= pb ? pa : pb;
    final pbase = _base(prevRow, plo, (pb - pa).abs());
    var total = 0;
    for (var w = 0; w < _words; w++) {
      total += _popcount32(_table[base + w] & ~_table[pbase + w]);
    }
    return total;
  }
}

/// Najlepszy ciąg kolumn przy ustalonym G, z wymiarem B.
///
/// Stan to `(a_r, a_{r+1}, b)` -- kolumny wejścia w dwa kolejne wiersze oraz
/// dotychczasowe B. Dwie kolumny są potrzebne, bo obciążenie miny wymaga
/// porównania odcinka bieżącego wiersza z poprzednim.
(List<int>?, int) _solveForGreen(
  GridField field,
  int green,
  ScoreParams params,
  SolverConfig cfg,
  double incumbent,
) {
  final rows = field.rows;
  final cols = field.cols;
  final grid = _blockedGrid(
    field,
    field.blocked(inflation: params.mineInflation),
  );
  final prefix = _blockedPrefix(field, grid);
  final stride = cols + 1;

  final missedCap = incumbent > 0.0
      ? math.max(
          0,
          math.min(
            cfg.maxMissed,
            ((1 + 2 * green) / (incumbent * rows)).floor() - 1,
          ),
        )
      : cfg.maxMissed;
  final width = missedCap + 1;

  if (rows == 1) {
    for (var x = 0; x < cols; x++) {
      if (grid[x] == 0) return ([x], missedCap);
    }
    return (null, missedCap);
  }

  final masks = _CoverMasks(field, green, cfg.maxLateral, params.shape);
  var dp = HashMap<int, List<double>>();
  final parents = List.generate(rows, (_) => HashMap<int, int>());

  for (var a0 = 0; a0 < cols; a0++) {
    if (grid[a0] != 0) continue;
    final from = math.max(0, a0 - cfg.maxLateral);
    final to = math.min(cols - 1, a0 + cfg.maxLateral);
    for (var a1 = from; a1 <= to; a1++) {
      if (grid[cols + a1] != 0 || !_spanFree(prefix, stride, 0, a0, a1)) {
        continue;
      }
      final charged = masks.newlyCharged(0, a0, a1, -1, 0, 0);
      if (charged > missedCap) continue;
      final costs = dp.putIfAbsent(
        a0 * cols + a1,
        () => List<double>.filled(width, _inf),
      );
      final steps = 1.0 + (a1 - a0).abs();
      if (steps < costs[charged]) costs[charged] = steps;
    }
  }

  for (var row = 1; row < rows - 1; row++) {
    final next = HashMap<int, List<double>>();
    for (final entry in dp.entries) {
      final aPrev = entry.key ~/ cols;
      final aCur = entry.key % cols;
      final costs = entry.value;
      var anyLive = false;
      for (final v in costs) {
        if (v < _inf) {
          anyLive = true;
          break;
        }
      }
      if (!anyLive) continue;

      final from = math.max(0, aCur - cfg.maxLateral);
      final to = math.min(cols - 1, aCur + cfg.maxLateral);
      for (var aNext = from; aNext <= to; aNext++) {
        if (grid[(row + 1) * cols + aNext] != 0 ||
            !_spanFree(prefix, stride, row, aCur, aNext)) {
          continue;
        }
        final charged = masks.newlyCharged(
          row,
          aCur,
          aNext,
          row - 1,
          aPrev,
          aCur,
        );
        if (charged > missedCap) continue;
        final move = 1.0 + (aNext - aCur).abs();
        final key = aCur * cols + aNext;
        final target = next.putIfAbsent(
          key,
          () => List<double>.filled(width, _inf),
        );
        for (var b = 0; b < width; b++) {
          if (costs[b] == _inf) continue;
          final nb = b + charged;
          if (nb > missedCap) continue;
          final steps = costs[b] + move;
          if (steps < target[nb]) {
            target[nb] = steps;
            parents[row][key * width + nb] = (aPrev * cols + aCur) * width + b;
          }
        }
      }
    }
    dp = next;
    if (dp.isEmpty) return (null, missedCap);
  }

  final last = rows - 1;
  var bestRatio = 0.0;
  int? bestKey;
  var bestB = 0;
  for (final entry in dp.entries) {
    final aPrev = entry.key ~/ cols;
    final aCur = entry.key % cols;
    final charged = masks.newlyCharged(last, aCur, aCur, last - 1, aPrev, aCur);
    for (var b = 0; b < entry.value.length; b++) {
      final steps = entry.value[b];
      if (steps == _inf) continue;
      final nb = b + charged;
      if (nb > missedCap) continue;
      final ratio = (1 + 2 * green) / ((1 + nb) * (steps + 1.0));
      if (ratio > bestRatio) {
        bestRatio = ratio;
        bestKey = entry.key;
        bestB = b;
      }
    }
  }
  if (bestKey == null) return (null, missedCap);

  var aPrev = bestKey ~/ cols;
  var aCur = bestKey % cols;
  var b = bestB;
  final columns = <int>[aCur, aPrev];
  for (var row = rows - 2; row >= 1; row--) {
    final packed = parents[row][(aPrev * cols + aCur) * width + b];
    if (packed == null) return (null, missedCap);
    final state = packed ~/ width;
    b = packed % width;
    aCur = aPrev;
    aPrev = state ~/ cols;
    columns.add(aPrev);
  }
  return (columns.reversed.toList(), missedCap);
}

/// Wspinaczka po *dokładnym* wyniku -- domyka lukę przybliżenia DP.
(List<int>, int, Score?) _hillClimb(
  GridField field,
  List<int> columns,
  int green,
  ScoreParams params,
  SolverConfig cfg,
) {
  final grid = _blockedGrid(
    field,
    field.blocked(inflation: params.mineInflation),
  );
  final prefix = _blockedPrefix(field, grid);
  final stride = field.cols + 1;

  bool legal(List<int> seq) {
    for (var row = 0; row < seq.length; row++) {
      final col = seq[row];
      if (col < 0 || col >= field.cols) return false;
      if (grid[row * field.cols + col] != 0) return false;
    }
    for (var row = 0; row < seq.length - 1; row++) {
      if (!_spanFree(prefix, stride, row, seq[row], seq[row + 1])) return false;
    }
    return true;
  }

  /// Sama wartość wyniku, bez budowania strefy zielonej ani obiektu [Score].
  ///
  /// Wspinaczka woła to tysiące razy, a pełny scorer alokuje przy każdym
  /// wywołaniu zbiór rzędu `wiersze * (2G+1)` komórek. Zwraca -1 dla ścieżki
  /// nielegalnej.
  double quickValue(List<int> seq, int g) {
    if (!legal(seq)) return -1.0;
    final cells = columnsToCells(seq);
    for (final cell in cells) {
      if (field.mines.contains(cell)) return -1.0;
    }
    final missed = missedMineCount(field, cells, g, shape: params.shape);
    final steps = cells.length;
    return 150000.0 *
        cellFeet *
        (1 + 2 * g) /
        ((1 + missed) * cellFeet * steps * params.penalty);
  }

  Score? evaluate(List<int> seq, int g) {
    if (!legal(seq)) return null;
    final result = scoreGridPath(field, columnsToPath(seq, g), params);
    return result.valid && result.minesOnPath == 0 ? result : null;
  }

  var bestValue = quickValue(columns, green);
  if (bestValue < 0) return (columns, green, null);

  var bestCols = List<int>.from(columns);
  var bestGreen = green;

  for (var round = 0; round < cfg.localSearchRounds; round++) {
    var improved = false;

    for (final g in [bestGreen - 1, bestGreen + 1]) {
      if (g < 0 || g > cfg.maxGreen) continue;
      final value = quickValue(bestCols, g);
      if (value > bestValue) {
        bestValue = value;
        bestGreen = g;
        improved = true;
      }
    }

    for (final shift in [-1, 1]) {
      final moved = [for (final c in bestCols) c + shift];
      final value = quickValue(moved, bestGreen);
      if (value > bestValue) {
        bestValue = value;
        bestCols = moved;
        improved = true;
      }
    }

    for (var row = 0; row < bestCols.length; row++) {
      for (final delta in [-1, 1]) {
        final candidate = List<int>.from(bestCols);
        candidate[row] += delta;
        final value = quickValue(candidate, bestGreen);
        if (value > bestValue) {
          bestValue = value;
          bestCols = candidate;
          improved = true;
        }
      }
    }

    if (!improved) break;
  }

  return (bestCols, bestGreen, evaluate(bestCols, bestGreen));
}

/// Wyznacza ścieżkę o najwyższym wyniku wg spec.txt.
///
/// G rośnie po kolei, bo każdy udany przebieg zacieśnia limit B dla kolejnych:
/// przy wyniku odniesienia `f` dopuszczalne B spełnia
/// `(1+2G) / ((1+B) * wiersze) > f`. W praktyce po pierwszym trafieniu limit
/// spada do kilku, więc wymiar B jest prawie darmowy.
GridSolution solveGrid(
  GridField field, {
  ScoreParams params = const ScoreParams(),
  SolverConfig cfg = const SolverConfig(),
}) {
  final timings = <String, double>{};
  final perGreen = <int, double>{};
  final caps = <int, int>{};
  final candidates = <List<int>>[];

  GridPath? bestPath;
  Score? bestResult;
  var incumbent = 0.0;

  void offer(List<int> columns, int green) {
    final (tunedCols, tuned, result) = _hillClimb(
      field,
      columns,
      green,
      params,
      cfg,
    );
    if (result == null) return;
    candidates.add(tunedCols);
    perGreen[tuned] = math.max(perGreen[tuned] ?? 0.0, result.value);
    if (bestResult == null || result.value > bestResult!.value) {
      bestResult = result;
      bestPath = columnsToPath(tunedCols, tuned);
      incumbent = (1 + 2 * tuned) / ((1 + result.missed) * result.steps);
    }
  }

  final watch = Stopwatch()..start();
  var cleanGreen = -1;
  for (var green = 0; green <= cfg.maxGreen; green++) {
    final columns = minStepsColumns(
      field,
      zeroMissedBlocked(field, green, params),
    );
    if (columns == null) break;
    cleanGreen = green;
    offer(columns, green);
  }
  timings['clean'] = watch.elapsedMicroseconds / 1000.0;

  if (cfg.refine) {
    final from = math.max(0, cleanGreen);
    final to = math.min(cfg.maxGreen, cleanGreen + 3);
    for (var green = from; green <= to; green++) {
      watch.reset();
      final (columns, cap) = _solveForGreen(
        field,
        green,
        params,
        cfg,
        incumbent,
      );
      caps[green] = cap;
      timings['g$green'] = watch.elapsedMicroseconds / 1000.0;
      if (columns != null) offer(columns, green);
    }
  }

  for (final columns in List<List<int>>.from(candidates)) {
    for (var green = 0; green <= cfg.maxGreen; green++) {
      final trial = scoreGridPath(field, columnsToPath(columns, green), params);
      if (!trial.valid || trial.minesOnPath > 0) continue;
      perGreen[green] = math.max(perGreen[green] ?? 0.0, trial.value);
      if (bestResult == null || trial.value > bestResult!.value) {
        bestResult = trial;
        bestPath = columnsToPath(columns, green);
      }
    }
  }

  if (bestPath == null || bestResult == null) {
    final blocked = field.blocked(inflation: params.mineInflation);

    final inField = field.cols * field.rows - field.outside.length;
    if (field.unscanned.length >= inField) {
      return GridSolution(
        found: false,
        reason:
            'nic nie zostało przeskanowane -- żaden dron nie zgłosił obszaru '
            'SCAN, więc całe pole jest nierozpoznane i nie ma czym poprowadzić '
            'ścieżki',
        perGreen: perGreen,
        missedCap: caps,
        timingsMs: timings,
      );
    }
    if (field.unscanned.isNotEmpty) {
      final percent = (100 * field.unscanned.length / inField).round();
      return GridSolution(
        found: false,
        reason:
            'brak przejścia przez teren rozpoznany -- $percent% pola jeszcze '
            'nie przeskanowano, a przez nierozpoznane komórki ścieżka nie '
            'przechodzi',
        perGreen: perGreen,
        missedCap: caps,
        timingsMs: timings,
      );
    }

    final reason = freeCellsConnect(field, blocked)
        ? 'wolne komórki łączą start z metą, ale nie da się ich przejść bez '
              'cofania -- wolne odcinki w kolejnych wierszach nie zazębiają '
              'się, więc ścieżka wymagałaby ruchów D'
        : 'brak przejścia: wolne komórki nie łączą linii startu z metą '
              '-- miny albo obrys pola przecinają pole w poprzek';
    return GridSolution(
      found: false,
      reason: reason,
      perGreen: perGreen,
      missedCap: caps,
      timingsMs: timings,
    );
  }

  return GridSolution(
    found: true,
    reason: bestResult!.reason,
    path: bestPath,
    result: bestResult,
    perGreen: perGreen,
    missedCap: caps,
    timingsMs: timings,
  );
}
