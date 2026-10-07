import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capstone_monitor/wifi_settings.dart';
import 'package:capstone_monitor/wifi_protocol.dart';
import 'support/provisioning_fake.dart';

Future<void> open(WidgetTester tester, FakeProvisioning fake) async {
  addTearDown(fake.close);
  await tester
      .pumpWidget(MaterialApp(home: DeviceWifiSettings(transport: fake)));
  await tester.pumpAndSettle();
}

Future<void> scan(WidgetTester tester, FakeProvisioning fake,
    {int auth = 3}) async {
  await tester.tap(find.text('Set Up Wi-Fi · Scan Wi-Fi'));
  await tester.pump();
  final tx = fake.writes.last[2];
  fake.network('Lab', transaction: tx, auth: auth);
  fake.scanDone(tx, 1);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Lab'));
  await tester.pumpAndSettle();
}

Future<void> submit(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Save and connect'));
  await tester.tap(find.text('Save and connect'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Connect'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('screen loads existing status and IP without inventing an SSID',
      (tester) async {
    final fake = FakeProvisioning()..status = [1, 2, 9, 0, 192, 168, 1, 42];
    await open(tester, fake);
    expect(find.text('Settings · Wi-Fi'), findsOneWidget);
    expect(find.text('IP address: 192.168.1.42'), findsOneWidget);
    expect(find.text('Change network · Scan Wi-Fi'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'protected scan selection prompts for password and supports show hide',
      (tester) async {
    final fake = FakeProvisioning();
    await open(tester, fake);
    await scan(tester, fake);
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.first).controller!.text, 'Lab');
    expect(tester.widget<TextField>(fields.last).obscureText, true);
    expect(tester.widget<TextField>(fields.last).enabled, true);
    await tester.ensureVisible(find.byTooltip('Show password'));
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(tester.widget<TextField>(fields.last).obscureText, false);
    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(tester.widget<TextField>(fields.last).obscureText, true);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'confirmation never displays the password and cancel clears it without writes',
      (tester) async {
    final fake = FakeProvisioning();
    await open(tester, fake);
    await tester.enterText(find.byType(TextField).first, 'HiddenLab');
    await tester.enterText(find.byType(TextField).last, 'sensitive-password');
    await tester.ensureVisible(find.text('Save and connect'));
    await tester.tap(find.text('Save and connect'));
    await tester.pumpAndSettle();
    expect(find.text('Connect ESP32 to "HiddenLab"?'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('sensitive-password')),
        findsNothing);
    expect(fake.writes, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '');
    expect(fake.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'manual entry submits only after confirmation and displays final success and IP',
      (tester) async {
    final fake = FakeProvisioning();
    await open(tester, fake);
    await tester
        .ensureVisible(find.text('Other Network / Enter SSID Manually'));
    await tester.tap(find.text('Other Network / Enter SSID Manually'));
    await tester.enterText(find.byType(TextField).first, 'ManualLab');
    await tester.enterText(find.byType(TextField).last, 'example123');
    await submit(tester);
    expect(fake.writes.where((b) => b.length > 4).expand((b) => b.skip(7)),
        credentialObject('ManualLab', 'example123'));
    expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '');
    fake.reportStatus([1, 1, 9, 0, 0, 0, 0, 0]);
    fake.reportStatus([1, 2, 9, 0, 192, 168, 1, 42]);
    final name = utf8.encode('ManualLab'),
        object = [9, ...utf8.encode('ManualLab'), 192, 168, 1, 42, 208];
    expect(name.length, 9);
    final tx = fake.writes.last[2];
    for (var offset = 0; offset < object.length; offset += 13) {
      final chunk =
          object.sublist(offset, (offset + 13).clamp(0, object.length));
      fake.notifications[provisioningData]!
          .add([1, 3, tx, 0, offset, object.length, chunk.length, ...chunk]);
    }
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.text('Connected successfully.'), findsOneWidget);
    expect(find.text('Connected to: ManualLab'), findsOneWidget);
    expect(find.text('IP address: 192.168.1.42'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'known open network needs no password and protected network rejects empty password',
      (tester) async {
    final fake = FakeProvisioning();
    await open(tester, fake);
    await scan(tester, fake, auth: 0);
    expect(find.text('Open network: no password required.'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField).last).enabled, false);
    await submit(tester);
    expect(fake.writes.where((b) => b.length > 4).expand((b) => b.skip(7)),
        credentialObject('Lab', ''));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('protected network requires password before confirmation',
      (tester) async {
    final fake = FakeProvisioning();
    await open(tester, fake);
    await scan(tester, fake);
    await tester.ensureVisible(find.text('Save and connect'));
    await tester.tap(find.text('Save and connect'));
    await tester.pump();
    expect(find.text('Enter the password for this secured network.'),
        findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(fake.writes.where((b) => b[1] == 3), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('cancel remains usable during a blocked credential write',
      (tester) async {
    final fake = FakeProvisioning();
    await open(tester, fake);
    final blocked = Completer<void>();
    fake.onWrite = (uuid, bytes) async {
      if (uuid == provisioningControl)
        fake.acknowledge(bytes);
      else {
        await blocked.future;
      }
    };
    await tester.enterText(find.byType(TextField).first, 'Lab');
    await tester.enterText(find.byType(TextField).last, 'example123');
    await submit(tester);
    expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '');
    await tester.ensureVisible(find.text('Cancel provisioning'));
    await tester.tap(find.text('Cancel provisioning'));
    await tester.pumpAndSettle();
    blocked.complete();
    await tester.pumpAndSettle();
    expect(fake.writes.where((b) => b.length == 4).map((b) => b[1]), [3, 6]);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('BLE disconnect clears an entered password', (tester) async {
    final fake = FakeProvisioning();
    await open(tester, fake);
    await tester.enterText(find.byType(TextField).first, 'Lab');
    await tester.enterText(find.byType(TextField).last, 'example123');
    fake.disconnected.add(null);
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '');
    expect(fake.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
