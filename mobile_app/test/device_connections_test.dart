import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/device_connections.dart';

void main() {
  testWidgets('connection page exposes BLE, USB and network setup on a phone',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Hardware discovery is only triggered by the user's scan/connect actions.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('capstone/connectivity'),
            (call) async => 'Wi-Fi');
    final api = Api();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('usb_serial/usb_events'), (_) async => null);
    await tester.pumpWidget(MaterialApp(
        home: DeviceConnections(
            api: api,
            log: CaptureLog(read: () async => null, write: (_) async {}))));
    await tester.pump();
    expect(find.text('Scan for ESP32'), findsOneWidget);
    await tester.tap(find.text('USB').first);
    await tester.pumpAndSettle();
    expect(find.text('Find USB devices'), findsOneWidget);
    expect(find.textContaining('diagnostic text only'), findsOneWidget);
    await tester.tap(find.text('Wi-Fi').first);
    await tester.pumpAndSettle();
    expect(find.text('Use Wi-Fi / UDP collector'), findsOneWidget);
    expect(find.text('Open Wi-Fi settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    api.close();
  });
}
