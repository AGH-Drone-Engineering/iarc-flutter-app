import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

class Drone {
  int id;
  String name;
  DateTime? lastSeen;
  Color mineDisplayColor;
  List<LatLng> points = [];

  static const int broadcast = 0x7F;

  static Map<int, Drone> registeredDronesMap = {};

  static Drone bajer1 = Drone._(0x01, "Bajer 1", Colors.red.shade300);
  static Drone bajer2 = Drone._(0x02, "Bajer 2", Colors.greenAccent);
  static Drone bajer3 = Drone._(0x03, "Bajer 3", Colors.lightGreenAccent);
  static Drone bajer4 = Drone._(0x04, "Bajer 4", Colors.amberAccent);

  static bool isValidId(int id) {
    return id == Drone.broadcast || Drone.registeredDronesMap.containsKey(id);
  }

  Drone._(this.id, this.name, [this.mineDisplayColor = Colors.deepOrangeAccent]) {
    Drone.registeredDronesMap[id] = this;
  }
}