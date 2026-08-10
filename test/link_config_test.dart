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

  test('a stored ACK timeout wider than the drone\'s dedupe window is clamped',
      () {
    // phone.log 2026-08-10: this was set to 10 s and persisted. Every retry
    // then reached the drone after its 5 s retransmission window had lapsed,
    // and was executed as a fresh command.
    final stored = LinkConfig.defaults([3]).copyWith(ackTimeoutMs: 10000).encode();
    final loaded = LinkConfig.decode(stored, [3]);

    expect(loaded.ackTimeoutMs, kAckTimeoutMsRange.max);
    expect(loaded.ackTimeoutMs, lessThan(kDroneDedupeWindowMs),
        reason: 'a retry has to arrive while the drone still remembers the q');
  });

  test('the settable range cannot express an interval the drone would miss', () {
    expect(kAckTimeoutMsRange.max, lessThan(kDroneDedupeWindowMs));
  });
}
