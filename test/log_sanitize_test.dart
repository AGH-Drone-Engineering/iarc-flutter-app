import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_esp_android_communication/services/global_log.dart';

void main() {
  group('sanitizeForLog', () {
    test('escapes newlines and carriage returns', () {
      expect(sanitizeForLog('a\nb\r\nc'), r'a\nb\n\nc');
    });

    test('escapes NUL and other control bytes as hex', () {
      expect(sanitizeForLog('a\x00b'), r'a\x00b');
      expect(sanitizeForLog('\x01\x1B'), r'\x01\x1b');
      expect(sanitizeForLog('\x7F'), r'\x7f');
    });

    test('leaves ordinary text untouched', () {
      expect(sanitizeForLog('[I][main] ready addr=0x03'),
          '[I][main] ready addr=0x03');
    });

    test('caps length and reports the original size', () {
      final long = 'x' * 5000;
      final out = sanitizeForLog(long, maxLength: 50);
      expect(out.length, lessThan(120));
      expect(out, contains('(5000 chars)'));
    });

    test('output survives JSON encoding for the session file', () {
      final nasty = 'a\x00\n"quote"\\slash\x1B[31m';
      final line = jsonEncode({'m': sanitizeForLog(nasty)});
      final round = jsonDecode(line) as Map<String, Object?>;
      expect(round['m'], isA<String>());
      expect(round['m'] as String, isNot(contains('\n')));
      expect(round['m'] as String, isNot(contains('\x00')));
    });

    test('maxLength <= 0 leaves the content uncapped but still escaped', () {
      final long = 'x' * 5000;
      expect(sanitizeForLog(long, maxLength: 0), long);
      expect(sanitizeForLog(long, maxLength: 0), isNot(contains('chars)')));

      final nasty = '${'A' * 3000}\n\x00';
      final out = sanitizeForLog(nasty, maxLength: 0);
      expect(out, contains('A' * 3000));
      expect(out, isNot(contains('\n')));
      expect(out, isNot(contains('\x00')));
    });

    test('a full-length binary blob cannot blow up a log line', () {
      final blob = String.fromCharCodes(List.generate(3072, (i) => i % 256));
      final out = sanitizeForLog(blob);
      expect(out.length, lessThan(1200));
      expect(out, contains('(3072 chars)'));
    });
  });

  group('printableRatio', () {
    test('reads a firmware log line as text', () {
      expect(printableRatio('[I][main] ready addr=0x03'.codeUnits),
          greaterThanOrEqualTo(0.9));
    });

    test('reads line noise as binary', () {
      expect(printableRatio([0x00, 0xFF, 0x80, 0x01, 0x02]), lessThan(0.9));
    });

    test('empty input is zero', () {
      expect(printableRatio(const []), 0);
    });
  });
}
