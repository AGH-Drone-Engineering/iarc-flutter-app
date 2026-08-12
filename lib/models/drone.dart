import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'mission_message.dart';

/// Jedna wykryta mina.
///
/// [id] jest nasze i zawsze różne. [tag] to numer z kodu Aruco i pełni rolę
/// nazwy, a nie tożsamości: ten sam znacznik może zostać naklejony na dwie miny
/// albo odczytany błędnie, więc dwa zgłoszenia z tym samym [tag] w różnych
/// miejscach to dwie miny, nie jedna. Odwrotnie też: dwa różne [tag] w tym
/// samym miejscu to dwie miny.
class MineReport {
  MineReport({
    required this.id,
    required this.tag,
    required this.position,
    required this.reportedBy,
    required this.at,
  });

  /// Wewnętrzny identyfikator, unikalny w obrębie sesji.
  final int id;

  /// Numer z kodu Aruco -- nazwa pokazywana operatorowi.
  final int tag;

  final LatLng position;
  final int reportedBy;
  final DateTime at;

  String get name => 'Mina $tag';
}

class Drone {
  final int id;
  final String name;
  final Color color;

  DateTime? lastSeen;
  DroneState state = DroneState.boot;
  LatLng? position;
  double? altitude;

  /// Horizontal position accuracy the drone last reported, in metres, or null
  /// when its receiver does not publish one. Null is "unknown", not "perfect".
  double? accuracyMeters;

  /// Ground speed from the drone's own EKF, in m/s.
  double? groundSpeed;
  double? battery;
  int? batteryPercent;
  MissionEvent? lastEvent;

  /// Pozycja z ostatniego zdarzenia, o ile je podało.
  ///
  /// Pole `at` w EVT jest opcjonalne -- zdarzenie bez sensownego fixa (ABORT po
  /// utracie pozycji) wychodzi bez niego. Null znaczy więc "dron nie powiedział
  /// gdzie", a nie "na zerowych współrzędnych".
  LatLng? lastEventAt;

  final List<LatLng> track = [];

  /// Waypointy głównej misji, które dron zgłosił jako osiągnięte.
  ///
  /// Trzymane osobno od [track]: ślad to gęsty strumień telemetrii, a to są
  /// punkty, w których dron sam uznał, że doleciał. Kumulują się przez całą
  /// misję, bo pokazują ile z planu jest już za nami.
  final List<LatLng> waypointsReached = [];

  Drone._(this.id, this.name, this.color) {
    registry[id] = this;
  }

  static const int minAddress = 1;
  static const int maxAddress = 31;

  static final Map<int, Drone> registry = {};

  static final Drone bajer1 = Drone._(0x01, 'Bajer 1', Colors.red.shade300);
  static final Drone bajer2 = Drone._(0x02, 'Bajer 2', Colors.greenAccent);
  static final Drone bajer3 = Drone._(0x03, 'Bajer 3', Colors.lightGreenAccent);
  static final Drone bajer4 = Drone._(0x04, 'Bajer 4', Colors.amberAccent);

  static void ensureRegistered() {
    if (registry.isNotEmpty) return;
    bajer1;
    bajer2;
    bajer3;
    bajer4;
  }

  static List<Drone> get all {
    ensureRegistered();
    return registry.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  static List<int> get allIds => all.map((d) => d.id).toList();

  static Drone? byId(int id) {
    ensureRegistered();
    return registry[id];
  }

  static String nameFor(int id) =>
      id == kBroadcastAddress ? 'All drones' : (byId(id)?.name ?? 'Node $id');

  static bool isValidDestination(int id) =>
      id == kBroadcastAddress || (id >= minAddress && id <= maxAddress);

  void applyTelemetry(TelemMessage t) {
    state = t.state;
    position = t.position;
    altitude = t.altitude;
    accuracyMeters = t.accuracyMeters;
    groundSpeed = t.groundSpeed;
    if (t.battery != null) battery = t.battery;
    if (t.batteryPercent != null) batteryPercent = t.batteryPercent;
    track.add(t.position);
    lastSeen = DateTime.now();
  }

  void markSeen() => lastSeen = DateTime.now();

  Duration? get sinceLastSeen =>
      lastSeen == null ? null : DateTime.now().difference(lastSeen!);

  bool get isStale {
    final since = sinceLastSeen;
    return since != null && since > const Duration(seconds: 5);
  }

  bool get hasEverReported => lastSeen != null;

  void reset() {
    lastSeen = null;
    state = DroneState.boot;
    position = null;
    altitude = null;
    accuracyMeters = null;
    groundSpeed = null;
    battery = null;
    batteryPercent = null;
    lastEvent = null;
    lastEventAt = null;
    track.clear();
    waypointsReached.clear();
  }
}
