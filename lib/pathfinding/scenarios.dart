/// Wbudowane scenariusze pola minowego -- do obejrzenia solvera bez dronów.
///
/// Miny są generowane deterministycznie z ustalonego ziarna, więc ten sam
/// scenariusz zawsze daje ten sam obrazek i da się o nim rozmawiać. Współrzędne
/// leżą w okolicy pola testowego z PROTOCOL.md.
///
/// Rozkłady min są dobrane tak, żeby pokazywać różne reżimy wyniku: przy polu
/// rzadkim wygrywa szeroka strefa zielona, przy gęstym wąski czysty korytarz,
/// a zapora zmusza do objazdu.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'grid_path.dart';
import 'local_frame.dart';

/// Gotowy zestaw: obrys pola, miny i pozycja obserwatora.
class Scenario {
  const Scenario({
    required this.name,
    required this.description,
    required this.corners,
    required this.mines,
    required this.observer,
  });

  final String name;
  final String description;

  /// Cztery narożniki pola.
  final List<LatLng> corners;

  final List<LatLng> mines;

  /// Pozycja telefonu -- decyduje, który bok jest linią startu.
  final LatLng observer;
}

/// Lewy narożnik linii startu pola testowego.
const LatLng _anchor = LatLng(50.0629750, 19.9157000);

/// Oficjalne pole: 80 x 300 stóp.
const double _fieldWidth = officialCols * cellMeters;
const double _fieldDepth = officialRows * cellMeters;

final LocalFrame _frame = LocalFrame(_anchor.latitude, _anchor.longitude);

LatLng _at(double u, double v, double bearingDeg) {
  final theta = bearingDeg * math.pi / 180.0;
  final cos = math.cos(theta);
  final sin = math.sin(theta);
  return _frame.toLatLng(Vec2(u * cos - v * sin, u * sin + v * cos));
}

List<LatLng> _corners({
  double width = _fieldWidth,
  double depth = _fieldDepth,
  double bearingDeg = 0.0,
  double topWidthFactor = 1.0,
  Vec2 cornerNudge = const Vec2(0, 0),
}) {
  final inset = width * (1.0 - topWidthFactor) / 2.0;
  return [
    _at(0, 0, bearingDeg),
    _at(width, 0, bearingDeg),
    _at(width - inset + cornerNudge.x, depth + cornerNudge.y, bearingDeg),
    _at(inset, depth, bearingDeg),
  ];
}

LatLng _observerFor(double bearingDeg) =>
    _at(_fieldWidth / 2, -6.0, bearingDeg);

List<LatLng> _uniform(int count, int seed, double bearingDeg) {
  final rng = math.Random(seed);
  return [
    for (var i = 0; i < count; i++)
      _at(
        rng.nextDouble() * _fieldWidth,
        rng.nextDouble() * _fieldDepth,
        bearingDeg,
      ),
  ];
}

List<LatLng> _clustered(int nests, int perNest, int seed, double bearingDeg) {
  final rng = math.Random(seed);
  final out = <LatLng>[];
  for (var n = 0; n < nests; n++) {
    final cu = rng.nextDouble() * _fieldWidth;
    final cv = rng.nextDouble() * _fieldDepth;
    for (var i = 0; i < perNest; i++) {
      final u = (cu + (rng.nextDouble() - 0.5) * 10.0).clamp(0.0, _fieldWidth);
      final v = (cv + (rng.nextDouble() - 0.5) * 10.0).clamp(0.0, _fieldDepth);
      out.add(_at(u, v, bearingDeg));
    }
  }
  return out;
}

List<LatLng> _belts(List<double> depths, int perBelt, int seed) {
  final rng = math.Random(seed);
  final out = <LatLng>[];
  for (final v in depths) {
    for (var i = 0; i < perBelt; i++) {
      final u = rng.nextDouble() * _fieldWidth;
      out.add(_at(u, v + (rng.nextDouble() - 0.5) * 2.0, 0.0));
    }
  }
  return out;
}

/// Scenariusze wbudowane w aplikację.
final List<Scenario> builtInScenarios = [
  Scenario(
    name: 'Puste pole',
    description:
        'Oficjalne 80 x 300 stóp bez min. Solver powinien iść prosto i wziąć '
        'największe dopuszczone G -- bez min nic nie ogranicza szerokości.',
    corners: _corners(),
    mines: const [],
    observer: _observerFor(0),
  ),
  Scenario(
    name: 'Rzadkie miny (60)',
    description:
        'Równomiernie, 60 min. Reżim, w którym opłaca się szeroka strefa '
        'zielona -- czysty korytarz jeszcze istnieje.',
    corners: _corners(),
    mines: _uniform(60, 11, 0),
    observer: _observerFor(0),
  ),
  Scenario(
    name: 'Gęste miny (250)',
    description:
        'Równomiernie, 250 min. Strefa zielona zbiera miny szybciej, niż '
        'rośnie W, więc wygrywa wąski korytarz i objazdy.',
    corners: _corners(),
    mines: _uniform(250, 12, 0),
    observer: _observerFor(0),
  ),
  Scenario(
    name: 'Gniazda',
    description:
        'Osiem gniazd po 20 min. Między gniazdami zostaje sporo miejsca, więc '
        'optymalne G bywa wyraźnie większe niż przy tej samej liczbie min '
        'rozrzuconych równomiernie.',
    corners: _corners(),
    mines: _clustered(8, 20, 13, 0),
    observer: _observerFor(0),
  ),
  Scenario(
    name: 'Zapory',
    description:
        'Trzy pasy w poprzek pola. Wymusza szukanie przerw, a nie prostej '
        'linii -- dobry test objazdów.',
    corners: _corners(),
    mines: _belts(const [20.0, 45.0, 70.0], 34, 14),
    observer: _observerFor(0),
  ),
  Scenario(
    name: 'Pole skośne',
    description:
        'To samo pole obrócone o 37 stopni. Siatka musi trzymać się linii '
        'startu, a nie północy.',
    corners: _corners(bearingDeg: 37.0),
    mines: _uniform(80, 15, 37.0),
    observer: _observerFor(37.0),
  ),
  Scenario(
    name: 'Pole trapezowe',
    description:
        'Dalszy bok węższy o ponad połowę, za dużo by wziąć to za błąd pomiaru. Komórki poza obrysem są nieprzejezdne, ale '
        'nie karzą jak miny -- widać to po masce siatki.',
    corners: _corners(topWidthFactor: 0.45),
    mines: _uniform(70, 16, 0),
    observer: _observerFor(0),
  ),
  Scenario(
    name: 'Źle zmierzony narożnik',
    description:
        'Prostokąt z jednym narożnikiem przesuniętym o ~4 m. Powinien zostać '
        'wykryty i poprawiony, z ostrzeżeniem wskazującym który to.',
    corners: _corners(cornerNudge: const Vec2(3.0, 2.5)),
    mines: _uniform(60, 17, 0),
    observer: _observerFor(0),
  ),
];
