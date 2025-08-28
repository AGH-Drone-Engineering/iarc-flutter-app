// lib/screens/map_tab.dart
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart' as fmtc;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/drone.dart';
import '../state/app_state.dart';
import '../widgets/ground_dots_layer.dart';

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
  StreamSubscription<MapEvent>? _mapSub;
  Timer? _recenterTimer;

  double? _headingDeg;
  double _mapRotationDeg = 0;
  LatLng? _user;
  double _zoom = 2;
  double _centerLat = 0;

  bool? _lastRotatePref;
  bool _isUserPanning = false;

  @override
  void initState() {
    super.initState();

    _tileProvider = fmtc.FMTCTileProvider(
      stores: const {'OSM': fmtc.BrowseStoreStrategy.readUpdateCreate},
      loadingStrategy: fmtc.BrowseLoadingStrategy.cacheFirst,
    );

    _initLocation();

    _compassSub = FlutterCompass.events?.listen((event) {
      if (!mounted) return;
      final h = event.heading;
      if (h != null && h.isFinite) {
        _headingDeg = h;

        final rotate = context.read<AppState>().rotateWithCompass;
        if (rotate) _rotateMapToHeading(h);
        setState(() {});
      }
    });

    // High-frequency, sub-second location updates
    final locationSettings = Platform.isAndroid
        ? AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      intervalDuration: Duration(milliseconds: 500),
    )
        : AppleSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      pauseLocationUpdatesAutomatically: false,
      activityType: ActivityType.fitness,
    );

    _posSub = Geolocator.getPositionStream(locationSettings: locationSettings).listen((pos) {
      if (!mounted) return;
      final next = LatLng(pos.latitude, pos.longitude);

      setState(() => _user = next);

      // Recenter on every GPS tick unless the user is actively panning
      if (!_isUserPanning) {
        _mapController.move(next, _zoom);
      }

      _recenterTimer?.cancel();
    });

    _mapSub = _mapController.mapEventStream.listen((evt) {
      if (!mounted) return;
      final cam = evt.camera;
      _zoom = cam.zoom;
      _centerLat = cam.center.latitude;
      _mapRotationDeg = cam.rotation;

      // Track panning state
      if (evt is MapEventMoveStart) {
        _isUserPanning = true;
        _recenterTimer?.cancel();
      } else if (evt is MapEventMove) {
        _isUserPanning = true;
      } else if (evt is MapEventMoveEnd) {
        _isUserPanning = false;
        // Optional snap-back when drag ends (kept for UX)
        if (_user != null) {
          _mapController.move(_user!, _zoom);
        }
      }

      setState(() {});
    });
  }

  Future<void> _initLocation() async {
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      await Geolocator.requestPermission();
    }
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      _user = LatLng(pos.latitude, pos.longitude);
      _centerLat = pos.latitude;
      _mapController.move(_user!, 18);
      setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _recenterTimer?.cancel();
    _compassSub?.cancel();
    _posSub?.cancel();
    _mapSub?.cancel();
    super.dispose();
  }

  double _metersPerPixel(double latDeg, double zoom) {
    const earth = 40075016.68557849;
    final latRad = latDeg * (math.pi / 180.0);
    return (math.cos(latRad) * earth) / (256.0 * math.pow(2.0, zoom));
  }

  void _rotateMapToHeading(double headingDeg) {
    final desired = (headingDeg % 360 + 360) % 360;
    final diff = (desired - _mapRotationDeg).abs();
    if (diff >= 1.0) {
      _mapController.rotate(-desired);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    // If the user just turned rotation OFF, gently reset map to north-up once.
    final rotatePref = app.rotateWithCompass;
    if (_lastRotatePref != rotatePref) {
      if (!rotatePref && _mapRotationDeg.abs() > 0.5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _mapController.rotate(0);
        });
      }
      _lastRotatePref = rotatePref;
    }

    final polygon = app.hasFourCorners
        ? [
      Polygon(
        points: app.orderedCorners,
        borderColor: Colors.indigo,
        borderStrokeWidth: 3,
        color: Colors.indigo.withValues(alpha: 0.15),
      ),
    ]
        : const <Polygon>[];

    final angleRad = ((_headingDeg ?? 0) * (math.pi / 180.0));

    final latForScale = _user?.latitude ?? _centerLat;
    final mpp = _metersPerPixel(latForScale, _zoom);
    final oneMeterPx = 1.0 / mpp;
    double userMarkerPx = (oneMeterPx * 0.7).clamp(6.0, 18.0).toDouble();
    final userMarkerRadius = userMarkerPx / 2.0;

    final drones = Drone.registeredDronesMap.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: const MapOptions(
            initialCenter: LatLng(0, 0),
            initialZoom: 2,
            interactionOptions: InteractionOptions(flags: InteractiveFlag.all),
            initialRotation: 0,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.esp_map',
              tileProvider: _tileProvider,
            ),

            if (polygon.isNotEmpty) PolygonLayer(polygons: polygon),

            // 1m ground dots
            for (var i = 0; i < drones.length; i++)
              GroundDotsLayer(
                points: drones[i].points,
                diameterMeters: 1.0,
                color: drones[i].mineDisplayColor,
                minPixelDiameter: 3.0,
              ),

            if (app.singlePoint != null)
              GroundDotsLayer(
                points: [app.singlePoint!],
                diameterMeters: 1.0,
                color: Colors.purpleAccent,
                minPixelDiameter: 3.0,
                innerColor: Colors.purpleAccent,
              ),
            if (_user != null)
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: _user!,
                    radius: userMarkerRadius,
                    color: Colors.blueAccent.withValues(alpha: 0.95),
                    borderStrokeWidth: 2,
                    borderColor: Colors.black,
                  ),
                ],
              ),
          ],
        ),

        // Heading chip
        Positioned(
          right: 12,
          top: 12,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.rotate(
                  angle: angleRad,
                  child: const Icon(Icons.navigation, color: Colors.white),
                ),
                const SizedBox(width: 8),
                Text(
                  _headingDeg == null ? '--°' : '${_headingDeg!.round()}°',
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
