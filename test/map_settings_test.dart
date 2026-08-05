import 'package:flutter_esp_android_communication/state/map_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _flushWrites() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MapSettings', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('bez zapisanych ustawień wszystko jest włączone', () async {
      final s = MapSettings();
      await s.init();

      expect(s.rotateWithCompass, isTrue);
      expect(s.snapToUser, isTrue);
      for (final layer in MapLayer.values) {
        expect(s.isVisible(layer), isTrue, reason: layer.name);
      }
    });

    test('czyta klucz kompasu zapisany przez starszą wersję', () async {
      SharedPreferences.setMockInitialValues({'rotate_with_compass_v1': false});

      final s = MapSettings();
      await s.init();

      expect(s.rotateWithCompass, isFalse);
      expect(s.snapToUser, isTrue);
    });

    test('wyłączona warstwa przeżywa restart', () async {
      final first = MapSettings();
      await first.init();
      first.setVisible(MapLayer.mines, false);
      await _flushWrites();

      final second = MapSettings();
      await second.init();

      expect(second.isVisible(MapLayer.mines), isFalse);
      expect(second.isVisible(MapLayer.drones), isTrue);
    });

    test('powiadamia tylko przy faktycznej zmianie', () {
      final s = MapSettings();
      var notifications = 0;
      s.addListener(() => notifications++);

      s.setSnapToUser(true);
      expect(notifications, 0);

      s.setSnapToUser(false);
      s.setVisible(MapLayer.user, false);
      s.setVisible(MapLayer.user, false);
      expect(notifications, 2);
    });
  });
}
