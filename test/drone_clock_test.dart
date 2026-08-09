import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/services/drone_clock.dart';

const _somewhere = LatLng(50.062975, 19.9157);

TelemMessage frame(int? sampleMs) => TelemMessage(
      seq: 1,
      position: _somewhere,
      altitude: 3.0,
      state: DroneState.hover,
      sampleMs: sampleMs,
    );

final _t0 = DateTime.utc(2026, 8, 9, 12, 0, 0);
DateTime at(int ms) => _t0.add(Duration(milliseconds: ms));

void main() {
  test('the drone clock never has to agree with ours', () {
    final clock = DroneClock();
    // The drone's counter starts wherever it likes -- here it is nowhere near
    // our epoch, which is the real situation: the Pi has no RTC.
    clock.observe(1, frame(7000), at(1000));
    clock.observe(1, frame(8000), at(2000));

    expect(clock.ageOf(1, frame(8000), at(2000)), Duration.zero);
    expect(clock.ageOf(1, frame(8000), at(2500)), const Duration(milliseconds: 500));
  });

  test('the offset estimate settles on the least delayed frame', () {
    final clock = DroneClock();
    clock.observe(1, frame(1000), at(3000));   // 2000 ms of queue
    clock.observe(1, frame(2000), at(3500));   // 1500 ms
    clock.observe(1, frame(3000), at(3200));   // 200 ms  <- the good one

    // The least delayed frame we have seen defines zero: we cannot know the
    // absolute one-way delay, only how much worse a frame is than the best.
    expect(clock.ageOf(1, frame(3000), at(3200)), Duration.zero);
    // Which makes the earlier frames measurably late relative to it.
    expect(clock.ageOf(1, frame(1000), at(3200)), const Duration(milliseconds: 2000));
  });

  test('a frame that queued is aged, not mistaken for a reboot', () {
    final clock = DroneClock();
    for (var i = 0; i < 5; i++) {
      clock.observe(1, frame(1000 + i * 100), at(1000 + i * 100));
    }
    // Delivered now, but sampled two seconds ago.
    final late = frame(1400 - 2000);
    clock.observe(1, late, at(1400));

    expect(clock.ageOf(1, late, at(1400)), const Duration(milliseconds: 2000),
        reason: 'the offset must survive an out-of-order frame');
    // A fresh frame afterwards still reads as fresh.
    expect(clock.ageOf(1, frame(1500), at(1500)), Duration.zero);
  });

  test('a reboot restarts the estimate instead of reporting nonsense', () {
    final clock = DroneClock(rebootSlack: const Duration(seconds: 30));
    clock.observe(1, frame(600000), at(600000));
    // Counter restarts near zero -- far below any queueing delay.
    clock.observe(1, frame(50), at(700000));

    expect(clock.ageOf(1, frame(50), at(700000)), Duration.zero);
    expect(clock.ageOf(1, frame(150), at(700100)), Duration.zero);
  });

  test('no timestamp means unknown, which is not the same as fresh', () {
    final clock = DroneClock();
    clock.observe(1, frame(null), at(1000));

    expect(clock.knows(1), isFalse);
    expect(clock.ageOf(1, frame(null), at(1000)), isNull);
  });
}
