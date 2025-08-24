// lib/main.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart' as fmtc;

import 'services/global_log.dart';   // <-- global logger (ChangeNotifier singleton)
import 'state/app_state.dart';
import 'screens/map_tab.dart';
import 'screens/logs_tab.dart';
import 'screens/esp_data_tab.dart';
import 'screens/inputs_tab.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Location permission (for the user location layer)
  await Geolocator.requestPermission();

  // FMTC v10+ initialisation (backend) + create a store named "OSM"
  await fmtc.FMTCObjectBoxBackend().initialise();
  await fmtc.FMTCStore('OSM').manage.create();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()..init()),
        // Provide the global logger so widgets can watch it and rebuild on notifyListeners()
        ChangeNotifierProvider<GlobalLog>.value(value: globalLog),
      ],
      child: MaterialApp(
        title: 'IARC 2025 App',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
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
  int _index = 1;
  final _pages = const [MapTab(), LogsTab(), EspDataTab(), InputsTab()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('IARC 2025 App')),
      body: _pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.list_alt), label: 'Logs'),
          NavigationDestination(icon: Icon(Icons.usb), label: 'ESP'),
          NavigationDestination(icon: Icon(Icons.edit_location_alt), label: 'Inputs'),
        ],
      ),
    );
  }
}
