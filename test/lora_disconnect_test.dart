import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_esp_android_communication/services/lora_link_service.dart';
import 'package:flutter_esp_android_communication/services/mission_transport.dart';

/// Unplugging the HAT board does not reliably close the serial input stream, so
/// the link has to notice by itself: every transfer starts failing and nothing
/// ever comes back. Before this, the UI stayed on "connected" and the 200 ms
/// poll wrote an error line for each attempt, indefinitely.
void main() {
  test('a single failed transfer is a blip, not a disconnect', () {
    final link = LoraLinkService();
    expect(link.noteIoFailureForTest('boom'), isTrue,
        reason: 'one failure must not tear the link down');
    expect(link.state, LinkState.disconnected,
        reason: 'never connected in this test, but nothing else changed it');
    link.dispose();
  });

  test('a run of failures gives up and disconnects', () {
    final link = LoraLinkService();
    var kept = 0;
    for (var i = 0; i < 10; i++) {
      if (!link.noteIoFailureForTest('boom')) break;
      kept++;
    }

    expect(kept, 3, reason: 'three retries, then the fourth calls it gone');
    expect(link.ioFailuresForTest, 4);
    link.dispose();
  });
}
