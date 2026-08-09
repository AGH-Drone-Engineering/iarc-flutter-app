import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_esp_android_communication/models/link_config.dart';

const _drones = [1, 2];

void main() {
  test('the ACK settings survive a round trip', () {
    final config = LinkConfig.defaults(_drones)
        .copyWith(ackTimeoutMs: 750, maxAttempts: 5);

    final back = LinkConfig.decode(config.encode(), _drones);

    expect(back.ackTimeoutMs, 750);
    expect(back.maxAttempts, 5);
    expect(back.worstCaseWait, const Duration(milliseconds: 3750));
  });

  test('a config stored before the settings existed reads as the defaults', () {
    final legacy = jsonEncode({
      'transport': 'udp',
      'listenPort': 14650,
      'endpoints': const [],
    });

    final back = LinkConfig.decode(legacy, _drones);

    expect(back.ackTimeoutMs, 2000);
    expect(back.maxAttempts, 3);
    expect(back.endpoints, hasLength(2), reason: 'defaults still fill the gaps');
  });

  test('a nonsense stored value is clamped, never armed', () {
    final raw = jsonEncode({
      'ackTimeoutMs': 0,
      'maxAttempts': 0,
      'endpoints': const [],
    });

    final back = LinkConfig.decode(raw, _drones);

    expect(back.ackTimeoutMs, kAckTimeoutMsRange.min,
        reason: 'a zero timeout would arm a retry loop with no gap');
    expect(back.maxAttempts, kMaxAttemptsRange.min);
  });
}
