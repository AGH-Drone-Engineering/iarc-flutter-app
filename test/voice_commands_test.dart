import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/services/voice_commands.dart';

void main() {
  final parser = VoiceCommandParser();

  T only<T extends VoiceIntent>(String phrase) {
    final r = parser.parse(phrase);
    expect(r.applyNow, hasLength(1), reason: phrase);
    return r.applyNow.single as T;
  }

  group('ustawienia demo', () {
    test('wysokość po polsku i angielsku', () {
      for (final phrase in [
        'ustaw wysokość na 5',
        'ustaw wysokosc na piec',
        'wysokość 5',
        'set altitude to 5',
        'set the demo altitude to five',
        'altitude 5',
        'ustaw wysokość demo na 5',
        'set the altitude for demo to 5',
      ]) {
        expect(only<SetDemoAltitudeIntent>(phrase).meters, 5.0, reason: phrase);
      }
    });

    test('promień', () {
      for (final phrase in [
        'ustaw promień na 8',
        'ustaw promien na osiem',
        'set radius to 8',
        'radius 8',
      ]) {
        expect(only<SetDemoRadiusIntent>(phrase).meters, 8.0, reason: phrase);
      }
    });

    test('liczba wierzchołków', () {
      for (final phrase in [
        'ustaw wierzchołki na 6',
        'ustaw liczbę boków na sześć',
        'set vertices to 6',
        'six vertices',
        'sześć boków',
      ]) {
        expect(only<SetDemoVerticesIntent>(phrase).count, 6, reason: phrase);
      }
    });

    test('ułamki dziesiętne, przecinkiem i kropką', () {
      expect(only<SetDemoRadiusIntent>('ustaw promień na 7,5').meters, 7.5);
      expect(only<SetDemoAltitudeIntent>('set altitude to 2.5').meters, 2.5);
    });

    test('wartość spoza zakresu jest przycinana, nie odrzucana', () {
      expect(only<SetDemoAltitudeIntent>('set altitude to 900').meters, 30.0);
      expect(only<SetDemoRadiusIntent>('ustaw promień na zero').meters, 1.0);
      expect(only<SetDemoVerticesIntent>('set vertices to 40').count, 16);
    });

    test('liczebniki dwucyfrowe nie gubią końcówki', () {
      expect(only<SetDemoVerticesIntent>('ustaw wierzchołki na dwanaście').count, 12);
      expect(only<SetDemoAltitudeIntent>('set altitude to fifteen').meters, 15.0);
    });
  });

  group('rozróżnienie wysokości demo i głównej', () {
    test('główna nie ustawia jednocześnie demo', () {
      for (final phrase in [
        'set main altitude to 10',
        'ustaw wysokość główną na 10',
        'ustaw wysokość przeszukiwania na 10',
        'set the search altitude to ten',
      ]) {
        final r = parser.parse(phrase);
        expect(r.applyNow, hasLength(1), reason: phrase);
        expect(r.applyNow.single, isA<SetMainAltitudeIntent>(), reason: phrase);
        expect((r.applyNow.single as SetMainAltitudeIntent).meters, 10.0,
            reason: phrase);
      }
    });
  });

  group('kilka ustawień w jednym zdaniu', () {
    test('promień i wierzchołki', () {
      final r = parser.parse('ustaw promień na 8 i wierzchołki na 6');
      expect(r.applyNow.whereType<SetDemoRadiusIntent>().single.meters, 8.0);
      expect(r.applyNow.whereType<SetDemoVerticesIntent>().single.count, 6);
      expect(r.needsConfirm, isNull);
    });

    test('wysokość, promień i komenda naraz', () {
      final r = parser.parse('set altitude to 4 and radius to 9 then start demo');
      expect(r.applyNow.whereType<SetDemoAltitudeIntent>().single.meters, 4.0);
      expect(r.applyNow.whereType<SetDemoRadiusIntent>().single.meters, 9.0);
      expect(r.needsConfirm, isA<StartDemoIntent>());
    });

    test('wszystkie nastawy w jednym zdaniu', () {
      final r = parser.parse(
          'ustaw wysokość 5, promień 8, wierzchołki 6 i wysokość główną 12');
      expect(r.applyNow.whereType<SetDemoAltitudeIntent>().single.meters, 5.0);
      expect(r.applyNow.whereType<SetDemoRadiusIntent>().single.meters, 8.0);
      expect(r.applyNow.whereType<SetDemoVerticesIntent>().single.count, 6);
      expect(r.applyNow.whereType<SetMainAltitudeIntent>().single.meters, 12.0);
    });

    test('obie wysokości naraz, mimo szyku po polsku', () {
      final r = parser.parse('ustaw wysokość główną na 10 i wysokość demo na 5');
      expect(r.applyNow.whereType<SetMainAltitudeIntent>().single.meters, 10.0);
      expect(r.applyNow.whereType<SetDemoAltitudeIntent>().single.meters, 5.0);
    });

    test('kolejność jest kolejnością wypowiedzi', () {
      expect(
        parser.parse('set radius 9 and vertices 6 and altitude 4').applyNow,
        [isA<SetDemoRadiusIntent>(), isA<SetDemoVerticesIntent>(),
            isA<SetDemoAltitudeIntent>()],
      );
      expect(
        parser.parse('set altitude 4 and vertices 6 and radius 9').applyNow,
        [isA<SetDemoAltitudeIntent>(), isA<SetDemoVerticesIntent>(),
            isA<SetDemoRadiusIntent>()],
      );
    });

    test('powtórzona nastawa to poprawka, liczy się ostatnia', () {
      expect(only<SetDemoRadiusIntent>('ustaw promień na 8, nie, promień na 12')
          .meters, 12.0);

      final r = parser.parse('set radius to 8 and vertices to 6 and radius to 12');
      expect(r.applyNow.whereType<SetDemoRadiusIntent>().single.meters, 12.0);
      expect(r.applyNow.whereType<SetDemoVerticesIntent>().single.count, 6);
    });
  });

  group('komendy', () {
    test('lecące do drona czekają na potwierdzenie', () {
      final cases = <String, Matcher>{
        'start demo': isA<StartDemoIntent>(),
        'uruchom misję demo': isA<StartDemoIntent>(),
        'start main': isA<StartMainIntent>(),
        'rozpocznij misję główną': isA<StartMainIntent>(),
        'land': isA<LandIntent>(),
        'ląduj': isA<LandIntent>(),
        'return home': isA<ReturnHomeIntent>(),
        'wracaj do domu': isA<ReturnHomeIntent>(),
        'status': isA<StatusIntent>(),
        'melduj': isA<StatusIntent>(),
      };

      cases.forEach((phrase, matcher) {
        final r = parser.parse(phrase);
        expect(r.needsConfirm, matcher, reason: phrase);
        expect(r.needsConfirm!.appliesImmediately, isFalse, reason: phrase);
        expect(r.applyNow, isEmpty, reason: phrase);
      });
    });

    test('stop demo działa od razu, bo tylko zatrzymuje pompę na ziemi', () {
      for (final phrase in ['stop demo', 'zatrzymaj', 'przerwij misję', 'abort']) {
        final r = parser.parse(phrase);
        expect(r.needsConfirm, isNull, reason: phrase);
        expect(r.applyNow.single, isA<StopDemoIntent>(), reason: phrase);
      }
    });

    test('powrót wygrywa z lądowaniem w jednym zdaniu', () {
      expect(parser.parse('return home and land').needsConfirm,
          isA<ReturnHomeIntent>());
    });

    test('"start demo" nie czyta się jako stop', () {
      expect(parser.parse('start demo').needsConfirm, isA<StartDemoIntent>());
    });
  });

  group('adresat', () {
    test('po nazwie, numerze i słowie', () {
      expect(parser.parse('bajer 2 land').target, 0x02);
      expect(parser.parse('dron 3 status').target, 0x03);
      expect(parser.parse('drone three status').target, 0x03);
      expect(parser.parse('0x04 ląduj').target, 0x04);
    });

    test('rozgłoszenie', () {
      for (final phrase in ['all drones land', 'wszystkie drony ląduj', 'broadcast status']) {
        expect(parser.parse(phrase).target, kBroadcastAddress, reason: phrase);
      }
    });

    test('nieistniejący dron nie ustawia adresata', () {
      expect(parser.parse('dron 9 status').target, isNull);
    });

    test('sam adresat to poprawne zdanie', () {
      final r = parser.parse('bajer 1');
      expect(r.target, 0x01);
      expect(r.error, isNull);
      expect(r.isEmpty, isFalse);
    });
  });

  group('brak dopasowania', () {
    test('puste zdanie', () {
      expect(parser.parse('   ').isEmpty, isTrue);
      expect(parser.parse('   ').error, isNull);
    });

    test('zdanie bez komendy zgłasza błąd', () {
      final r = parser.parse('jaka dzisiaj ładna pogoda');
      expect(r.error, isNotNull);
      expect(r.isEmpty, isTrue);
    });
  });
}
