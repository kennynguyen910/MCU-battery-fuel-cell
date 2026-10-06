import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capstone_monitor/wifi_protocol.dart';
import 'package:capstone_monitor/wifi_settings.dart';
import 'package:capstone_monitor/wifi_transport.dart';

class FakeProvisioning implements ProvisioningTransport {
  final notifications = {
    for (final uuid in [
      provisioningControl,
      provisioningData,
      provisioningStatus
    ])
      uuid: StreamController<List<int>>.broadcast(sync: true)
  };
  final writes = <List<int>>[];
  List<int> status = [1, 0, 8, 0, 0, 0, 0, 0];
  bool noService = false;
  int? reject;
  Future<void> Function(String, List<int>)? onWrite;
  @override
  Future<void> discover() async {
    if (noService) throw StateError('Firmware missing provisioning service');
  }

  @override
  Stream<List<int>> subscribe(String characteristic) =>
      notifications[characteristic]!.stream;
  @override
  Future<List<int>> readStatus() async => status;
  @override
  Future<void> write(String characteristic, List<int> bytes) async {
    writes.add(List.of(bytes));
    if (onWrite != null) {
      await onWrite!(characteristic, bytes);
      return;
    }
    if (characteristic == provisioningControl) {
      notifications[provisioningControl]!.add([
        1,
        reject == bytes[1] ? 0x81 : 0x80,
        bytes[2],
        2,
        bytes[1],
        reject == bytes[1] ? 8 : 0
      ]);
    }
  }

  Future<void> close() async {
    for (final controller in notifications.values) {
      await controller.close();
    }
  }
}

Future<void> open(WidgetTester tester, FakeProvisioning transport) async {
  await tester
      .pumpWidget(MaterialApp(home: DeviceWifiSettings(transport: transport)));
  await tester.pumpAndSettle();
}

Future<void> enterCredentials(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).at(0), 'LabWiFi');
  await tester.enterText(find.byType(TextField).at(1), 'example123');
}

void main() {
  testWidgets(
      'fresh device offers setup and credentials use BEGIN fragments COMMIT',
      (tester) async {
    final transport = FakeProvisioning();
    addTearDown(transport.close);
    await open(tester, transport);
    expect(find.textContaining('Set up Wi-Fi?'), findsOneWidget);
    await enterCredentials(tester);
    await tester.tap(find.text('Save and connect'));
    await tester.pumpAndSettle();
    final commands = transport.writes
        .where((packet) => packet[1] == 3 || packet[1] == 4)
        .toList();
    expect(commands.map((packet) => packet[1]), [3, 4]);
    expect(commands[0][2], commands[1][2]);
    final data = transport.writes
        .where((packet) => packet.length > 4 && packet[1] == 1)
        .toList();
    expect(data.every((packet) => packet.length <= 20), true);
    expect(data.expand((packet) => packet.skip(7)),
        credentialObject('LabWiFi', 'example123'));
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        '');
    transport.notifications[provisioningStatus]!.add([1, 3, 8, 10, 0, 0, 0, 0]);
    await tester.pump();
    expect(find.textContaining('Check the password'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'security is reread after pairing rather than trusting stale flags',
      (tester) async {
    final transport = FakeProvisioning()..status[2] = 0;
    addTearDown(transport.close);
    await open(tester, transport);
    await enterCredentials(tester);
    transport.status[2] = 8;
    await tester.tap(find.text('Save and connect'));
    await tester.pumpAndSettle();
    expect(transport.writes.last[1], 4);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('unsecured connection sends no credentials', (tester) async {
    final transport = FakeProvisioning()..status[2] = 0;
    addTearDown(transport.close);
    await open(tester, transport);
    await enterCredentials(tester);
    await tester.tap(find.text('Save and connect'));
    await tester.pumpAndSettle();
    expect(transport.writes, isEmpty);
    expect(find.textContaining('encrypted BLE connection'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('scans reassemble results and late scan failure permits retry',
      (tester) async {
    final transport = FakeProvisioning();
    addTearDown(transport.close);
    await open(tester, transport);
    await tester.tap(find.text('Change network · Scan Wi-Fi'));
    await tester.pump();
    final transaction = transport.writes.single[2];
    transport.notifications[provisioningData]!
        .add([1, 2, transaction, 0, 0, 7, 7, 0, 208, 7, 3, 65, 66, 67]);
    await tester.pump();
    expect(find.text('ABC'), findsOneWidget);
    expect(find.textContaining('Unsupported in this version'), findsOneWidget);
    transport.notifications[provisioningControl]!
        .add([1, 0x81, transaction, 2, 2, 6]);
    await tester.pumpAndSettle();
    expect(find.text('Network scan failed. Try again.'), findsOneWidget);
    await tester.tap(find.text('Change network · Scan Wi-Fi'));
    await tester.pump();
    expect(transport.writes.length, 2);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'error ACK aborts transfer and sends CANCEL using the same transaction',
      (tester) async {
    final transport = FakeProvisioning()..reject = 3;
    addTearDown(transport.close);
    await open(tester, transport);
    await enterCredentials(tester);
    await tester.tap(find.text('Save and connect'));
    await tester.pumpAndSettle();
    expect(transport.writes.map((packet) => packet[1]), [3, 6]);
    expect(transport.writes.first[2], transport.writes.last[2]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('leaving during a transfer cancels and never commits',
      (tester) async {
    final transport = FakeProvisioning();
    addTearDown(transport.close);
    final pending = Completer<void>();
    transport.onWrite = (uuid, bytes) async {
      if (uuid == provisioningControl && bytes[1] == 3) {
        transport.notifications[provisioningControl]!
            .add([1, 0x80, bytes[2], 2, 3, 0]);
      } else if (uuid == provisioningData) {
        await pending.future;
      }
    };
    await open(tester, transport);
    await enterCredentials(tester);
    await tester.tap(find.text('Save and connect'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    expect(transport.writes.where((packet) => packet[1] == 4), isEmpty);
    expect(transport.writes.any((packet) => packet[1] == 6), true);
    expect(tester.takeException(), isNull);
  });
  testWidgets('forget sends CLEAR and missing firmware is explicit',
      (tester) async {
    final transport = FakeProvisioning();
    addTearDown(transport.close);
    await open(tester, transport);
    await tester.ensureVisible(find.text('Forget network'));
    await tester.tap(find.text('Forget network'));
    await tester.pumpAndSettle();
    expect(transport.writes.single[1], 5);
    await tester.pumpWidget(const SizedBox());
    transport.noService = true;
    await open(tester, transport);
    expect(find.textContaining('Firmware missing'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
