import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart' as fmtc;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

class MapTab extends StatefulWidget {
  const MapTab({super.key});
  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final MapController _mapController = MapController();
  late final fmtc.FMTCTileProvider _tileProvider;

  StreamSubscription<CompassEvent>? _compassSub;
  StreamSubscription<Position>? _posSub;

  double? _headingMag;       // magnetometer heading [0..360)
  double? _headingCourse;    // GPS course/bearing [0..360), -1 if unknown
  double _lastValidHeading = 0.0; // persisted fallback, always finite

  @override
  void initState() {
    super.initState();

    // FMTC v10+ cache-first provider
    _tileProvider = fmtc.FMTCTileProvider(
      stores: const {'OSM': fmtc.BrowseStoreStrategy.readUpdateCreate},
      loadingStrategy: fmtc.BrowseLoadingStrategy.cacheFirst,
    );

    _initLocation();
    _startGpsHeadingFallback();
    _startCompass();
  }

  Future<void> _initLocation() async {
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      await Geolocator.requestPermission();
    }
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      _mapController.move(LatLng(pos.latitude, pos.longitude), 15);
    } catch (_) {/* ignore */}
  }

  void _startCompass() {
    _compassSub = FlutterCompass.events?.listen((event) {
      if (!mounted) return;
      final h = event.heading;
      if (h != null && h.isFinite) {
        _headingMag = h;
        _lastValidHeading = h;
        setState(() {});
      }
      // if null/NaN/Inf, keep showing last valid or GPS course
    });
  }

  void _startGpsHeadingFallback() {
    const settings = LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 1, // meters
    );
    _posSub = Geolocator.getPositionStream(locationSettings: settings).listen((pos) {
      if (!mounted) return;
      final h = pos.heading; // -1 if not available
      if (h.isFinite && h >= 0) {
        _headingCourse = h;
        // don't overwrite _lastValidHeading; that tracks last *mag* or course used
        setState(() {});
      }
    }, onError: (_) {/* ignore */});
  }

  @override
  void dispose() {
    _compassSub?.cancel();
    _posSub?.cancel();
    super.dispose();
  }

  double _safeHeadingDeg() {
    if (_headingMag != null && _headingMag!.isFinite) return _headingMag!;
    if (_headingCourse != null && _headingCourse!.isFinite && _headingCourse! >= 0) {
      _lastValidHeading = _headingCourse!;
      return _headingCourse!;
    }
    return _lastValidHeading; // always finite
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    final polygon = app.hasFourCorners
        ? [
      Polygon(
        points: app.corners.whereType<LatLng>().toList(),
        borderColor: Colors.indigo,
        borderStrokeWidth: 3,
        color: Colors.indigo.withValues(alpha: .15),
      ),
    ]
        : <Polygon>[];

    final espMarkers = app.espPoints
        .map(
          (p) => Marker(
        point: p,
        width: 36,
        height: 36,
        child: const Icon(Icons.location_on, color: Colors.red, size: 30),
      ),
    )
        .toList();

    final headingDeg = _safeHeadingDeg();
    final angleRad = headingDeg * (math.pi / 180.0); // guaranteed finite
    final headingText = '${headingDeg.round()}°';

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: const MapOptions(
            initialCenter: LatLng(0, 0),
            initialZoom: 2,
            // Disable map rotation so compass behavior is predictable after pinch-zoom
            interactionOptions: InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.esp_map',
              tileProvider: _tileProvider,
            ),
            const CurrentLocationLayer(
              alignPositionOnUpdate: AlignOnUpdate.always,
              alignDirectionOnUpdate: AlignOnUpdate.never,
            ),
            if (polygon.isNotEmpty) PolygonLayer(polygons: polygon),
            if (espMarkers.isNotEmpty) MarkerLayer(markers: espMarkers),
          ],
        ),
        Positioned(
          right: 12,
          top: 12,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.rotate(
                  angle: angleRad, // never NaN/Inf
                  child: const Icon(Icons.navigation, color: Colors.white),
                ),
                const SizedBox(width: 8),
                Text(headingText, style: const TextStyle(color: Colors.white)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
