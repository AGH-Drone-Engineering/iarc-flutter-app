import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'mission_message.dart';

class MineReport {
  final int tag;
  final LatLng position;
  final int reportedBy;
  final DateTime at;

  MineReport({
    required this.tag,
    required this.position,
    required this.reportedBy,
    required this.at,
  });
}

class Drone {
  final int id;
  final String name;
  final Color color;

  DateTime? lastSeen;
  DroneState state = DroneState.boot;
  LatLng? position;
  double? altitude;
  double? battery;
  MissionEvent? lastEvent;

  final List<LatLng> track = [];

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
    if (t.battery != null) battery = t.battery;
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
    battery = null;
    lastEvent = null;
    track.clear();
  }
}
