import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Warstwy, które można pokazać albo ukryć na mapie.
enum MapLayer {
  drones,
  droneTracks,
  waypoints,
  mines,
  user,
  path,
  coverage,
  scanRects,
}

extension MapLayerDisplay on MapLayer {
  String get label => switch (this) {
        MapLayer.drones => 'Drony',
        MapLayer.droneTracks => 'Trasy dronów',
        MapLayer.waypoints => 'Osiągnięte waypointy',
        MapLayer.mines => 'Miny',
        MapLayer.user => 'Twoja pozycja',
        MapLayer.path => 'Bezpieczna ścieżka',
        MapLayer.coverage => 'Pokrycie skanem',
        MapLayer.scanRects => 'Prostokąty skanów',
      };

  IconData get icon => switch (this) {
        MapLayer.drones => Icons.flight,
        MapLayer.droneTracks => Icons.timeline,
        MapLayer.waypoints => Icons.flag,
        MapLayer.mines => Icons.dangerous,
        MapLayer.user => Icons.my_location,
        MapLayer.path => Icons.route,
        MapLayer.coverage => Icons.grid_view,
        MapLayer.scanRects => Icons.crop_square,
      };
}

/// Ustawienia widoku mapy -- co rysować i jak podążać za operatorem.
///
/// Trzymane osobno od AppState, bo dotyczą wyłącznie prezentacji: nic tu nie
/// leci w radio i nic nie zmienia stanu misji.
class MapSettings extends ChangeNotifier {
  static const _kRotateWithCompassKey = 'rotate_with_compass_v1';
  static const _kSnapToUserKey = 'snap_to_user_v1';

  static String _layerKey(MapLayer layer) => 'map_layer_${layer.name}_v1';

  SharedPreferences? _prefs;
  Future<SharedPreferences> _ensurePrefs() async =>
      _prefs ??= await SharedPreferences.getInstance();

  bool rotateWithCompass = true;
  bool snapToUser = true;

  /// Tylko wyłączone warstwy -- brak wpisu znaczy "widoczna".
  final Set<MapLayer> _hidden = {};

  bool isVisible(MapLayer layer) => !_hidden.contains(layer);

  Future<void> init() async {
    final p = await _ensurePrefs();
    rotateWithCompass = p.getBool(_kRotateWithCompassKey) ?? true;
    snapToUser = p.getBool(_kSnapToUserKey) ?? true;
    _hidden
      ..clear()
      ..addAll(MapLayer.values.where((l) => p.getBool(_layerKey(l)) == false));
    notifyListeners();
  }

  void setRotateWithCompass(bool v) {
    if (rotateWithCompass == v) return;
    rotateWithCompass = v;
    notifyListeners();
    _persist(_kRotateWithCompassKey, v);
  }

  void setSnapToUser(bool v) {
    if (snapToUser == v) return;
    snapToUser = v;
    notifyListeners();
    _persist(_kSnapToUserKey, v);
  }

  void setVisible(MapLayer layer, bool visible) {
    if (isVisible(layer) == visible) return;
    if (visible) {
      _hidden.remove(layer);
    } else {
      _hidden.add(layer);
    }
    notifyListeners();
    _persist(_layerKey(layer), visible);
  }

  Future<void> _persist(String key, bool v) async {
    (await _ensurePrefs()).setBool(key, v);
  }
}
