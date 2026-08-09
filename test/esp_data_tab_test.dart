import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_esp_android_communication/screens/esp_data_tab.dart';
import 'package:flutter_esp_android_communication/state/app_state.dart';

Future<AppState> pumpTab(WidgetTester tester) async {
  // Tall enough for the whole tab: the ListView does not build the cards that
  // fall below the default 600px surface.
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('usb_serial'),
          (call) async => call.method == 'listDevices' ? <Object?>[] : null);

  final app = AppState();
  await app.init();

  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: EspDataTab())),
    ),
  );
  await tester.pumpAndSettle();
  return app;
}

Future<void> type(WidgetTester tester, String label, String value) async {
  await tester.enterText(
    find.ancestor(of: find.text(label), matching: find.byType(TextField)),
    value,
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the ACK settings are editable and reach the tracker',
      (tester) async {
    final app = await pumpTab(tester);
    addTearDown(app.dispose);

    expect(app.tracker.ackTimeout, const Duration(milliseconds: 2000));
    expect(find.text('ACK & retries'), findsOneWidget);

    await type(tester, 'ACK timeout', '750');
    await type(tester, 'Attempts', '5');

    expect(app.tracker.ackTimeout, const Duration(milliseconds: 750));
    expect(app.tracker.maxAttempts, 5);
    expect(app.config.ackTimeoutMs, 750, reason: 'and it is what gets saved');
    expect(find.text('3.8 s'), findsOneWidget, reason: '750 ms x 5 attempts');
  });

  testWidgets('an out-of-range entry is clamped rather than applied',
      (tester) async {
    final app = await pumpTab(tester);
    addTearDown(app.dispose);

    await type(tester, 'ACK timeout', '0');
    expect(app.tracker.ackTimeout.inMilliseconds, 100);

    await type(tester, 'Attempts', '99');
    expect(app.tracker.maxAttempts, 10);
  });

  testWidgets('the debug button needs a link, and toggles when it has one',
      (tester) async {
    final app = await pumpTab(tester);
    addTearDown(app.dispose);

    final button = find.widgetWithText(FilledButton, 'Start');
    expect(button, findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull,
        reason: 'nothing to send to while the link is down');
    expect(app.debug.isRunning, isFalse);

    await type(tester, 'Interval', '250');
    expect(app.debug.interval, const Duration(milliseconds: 250));

    // The link cannot be brought up in a test, so drive the service directly
    // and check the card follows it.
    app.debug.start(dest: 1);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Stop'), findsOneWidget);
    expect(find.text('node 1'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
    await tester.pumpAndSettle();
    expect(app.debug.isRunning, isFalse);
    expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);
  });
}
