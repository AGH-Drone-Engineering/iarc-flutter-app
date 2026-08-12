import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart' as fmtc;

import 'models/drone.dart';
import 'services/global_log.dart';
import 'state/app_state.dart';
import 'state/map_settings.dart';
import 'state/path_state.dart';
import 'screens/map_tab.dart';
import 'screens/logs_tab.dart';
import 'screens/path_tab.dart';
import 'screens/esp_data_tab.dart';
import 'screens/inputs_tab.dart';
import 'screens/mission_tab.dart';
import 'screens/demo_tab.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);

  await globalLog.init();
  Drone.ensureRegistered();
  await Geolocator.requestPermission();

  await fmtc.FMTCObjectBoxBackend().initialise();
  await fmtc.FMTCStore('OSM').manage.create();

  final appState = AppState();
  await appState.init();

  final mapSettings = MapSettings();
  await mapSettings.init();

  runApp(MyApp(appState: appState, mapSettings: mapSettings));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.appState, required this.mapSettings});

  final AppState appState;
  final MapSettings mapSettings;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: appState),
        ChangeNotifierProvider<MapSettings>.value(value: mapSettings),
        ChangeNotifierProvider<GlobalLog>.value(value: globalLog),
        ChangeNotifierProvider<PathState>(create: (_) => PathState(appState)),
      ],
      child: MaterialApp(
        title: 'IARC 2026',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
        ),
        home: const HomeTabs(),
      ),
    );
  }
}

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int _index = 0;

  static const _pages = <Widget>[
    MissionTab(),
    DemoTab(),
    MapTab(),
    InputsTab(),
    LogsTab(),
    EspDataTab(),
    PathTab(),
  ];

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.rocket_launch_outlined),
      selectedIcon: Icon(Icons.rocket_launch),
      label: 'Mission',
    ),
    NavigationDestination(
      icon: Icon(Icons.change_history_outlined),
      selectedIcon: Icon(Icons.change_history),
      label: 'Demo',
    ),
    NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Map'),
    NavigationDestination(icon: Icon(Icons.edit_location_alt), label: 'Field'),
    NavigationDestination(icon: Icon(Icons.list_alt), label: 'Logs'),
    NavigationDestination(icon: Icon(Icons.usb), label: 'Link'),
    NavigationDestination(icon: Icon(Icons.route), label: 'Path'),
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final alerts = app.tracker.failures.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('IARC 2026'),
        actions: [
          if (!app.isConnected)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Chip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.usb_off, size: 16),
                label: const Text('Offline'),
              ),
            ),
        ],
      ),
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (var i = 0; i < _destinations.length; i++)
            if (i == 0 && alerts > 0)
              NavigationDestination(
                icon: Badge.count(count: alerts, child: _destinations[i].icon),
                selectedIcon: Badge.count(
                  count: alerts,
                  child: _destinations[i].selectedIcon ?? _destinations[i].icon,
                ),
                label: _destinations[i].label,
              )
            else
              _destinations[i],
        ],
      ),
    );
  }
}
