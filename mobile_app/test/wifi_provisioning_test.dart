import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:capstone_monitor/wifi_provisioning.dart';
import 'package:capstone_monitor/wifi_protocol.dart';
import 'support/provisioning_fake.dart';

final _activeModels = <WifiProvisioning>[];
void provisioningTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final model in _activeModels) {
        model.dispose();
      }
      _activeModels.clear();
      await tester.pump();
    }
  });
}

Future<WifiProvisioning> setup(
  FakeProvisioning fake, {
  Duration commandTimeout = const Duration(seconds: 10),
  Duration scanTimeout = const Duration(seconds: 60),
  Duration connectionTimeout = const Duration(seconds: 60),
}) async {
  final model = WifiProvisioning(fake,
      commandTimeout: commandTimeout,
      scanTimeout: scanTimeout,
      connectionTimeout: connectionTimeout);
  addTearDown(fake.close);
  _activeModels.add(model);
  await model.initialize();
  return model;
}

void main() {
  provisioningTest(
      'status initialization and NETWORK_INFO show the actual network',
      (tester) async {
    final fake = FakeProvisioning()..status = [1, 2, 9, 0, 192, 168, 1, 42];
    final model = await setup(fake);
    expect(model.phase, ProvisioningPhase.connected);
    expect(model.status!.ip, '192.168.1.42');
    fake.notifications[provisioningData]!
        .add([1, 3, 0, 0, 0, 9, 9, 3, 76, 97, 98, 192, 168, 1, 42, 208]);
    expect(model.currentNetwork, 'Lab');
  });
  provisioningTest(
      'scan deduplicates by strongest signal and ignores stale results',
      (tester) async {
    final fake = FakeProvisioning(), scanModel = await setup(fake);
    await scanModel.scan();
    final tx = fake.writes.single[2];
    fake.network('Lab', transaction: tx, index: 0, rssi: -70);
    fake.network('Lab', transaction: tx, index: 1, rssi: -40);
    fake.network('Stale', transaction: tx + 1);
    fake.scanDone(tx, 2);
    expect(scanModel.networks.keys, ['Lab']);
    expect(scanModel.networks['Lab']!.rssi, -40);
    expect(scanModel.busy, false);
  });
  provisioningTest('empty scan permits manual entry and refresh',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    await model.scan();
    fake.scanDone(fake.writes.last[2], 0);
    expect(model.message, contains('No networks found'));
    await model.scan();
    expect(fake.writes.length, 2);
  });
  provisioningTest(
      'scan timeout is understandable and retry starts a fresh transaction',
      (tester) async {
    final fake = FakeProvisioning(),
        model = await setup(fake, scanTimeout: const Duration(seconds: 1));
    await model.scan();
    final first = fake.writes.single[2];
    await tester.pump(const Duration(seconds: 1));
    expect(model.message, 'Scan timed out. Try again.');
    await model.scan();
    expect(fake.writes.last[2], isNot(first));
  });
  provisioningTest(
      'matching BEGIN and COMMIT ACKs preserve fragmentation and wait for connection',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    await model.provision('LabWiFi', 'example123');
    final control = fake.writes.where((b) => b.length == 4).toList();
    expect(control.map((b) => b[1]), [3, 4]);
    expect(control[0][2], control[1][2]);
    final fragments = fake.writes.where((b) => b.length > 4).toList();
    expect(fragments.length, greaterThan(1));
    expect(fragments.every((b) => b.length <= 20), true);
    expect(fragments.expand((b) => b.skip(7)),
        credentialObject('LabWiFi', 'example123'));
    expect(model.credentialsAcknowledged, true);
    expect(model.phase, ProvisioningPhase.connectingToWifi);
    expect(model.message, contains('ESP32 received credentials'));
    fake.reportStatus([1, 1, 9, 0, 0, 0, 0, 0]);
    fake.reportStatus([1, 2, 9, 0, 192, 168, 1, 42]);
    expect(model.phase, ProvisioningPhase.connected);
    expect(model.status!.ip, '192.168.1.42');
  });
  provisioningTest(
      'wrong transaction and opcode ACKs are ignored until matching ACK arrives',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    List<int>? begin;
    fake.onWrite = (uuid, bytes) async {
      if (uuid != provisioningControl) return;
      if (bytes[1] == 3) {
        begin = List.of(bytes);
        fake.acknowledge(bytes, transaction: bytes[2] + 1);
        fake.acknowledge(bytes, opcode: 4);
      } else {
        fake.acknowledge(bytes);
      }
    };
    final pending = model.provision('Lab', 'example123');
    await tester.pump();
    expect(model.phase, ProvisioningPhase.waitingForAcknowledgement);
    expect(fake.writes.length, 1);
    fake.acknowledge(begin!);
    await pending;
    expect(model.credentialsAcknowledged, true);
  });
  provisioningTest('ACK timeout cancels staging and retry works',
      (tester) async {
    final fake = FakeProvisioning(),
        model = await setup(fake, commandTimeout: const Duration(seconds: 1));
    fake.onWrite = (uuid, bytes) async {
      if (uuid == provisioningControl && bytes[1] == 6) fake.acknowledge(bytes);
    };
    final pending = model.provision('Lab', 'example123');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await pending;
    expect(model.message, contains('did not acknowledge'));
    expect(fake.writes.map((b) => b[1]), [3, 6]);
    fake.onWrite = null;
    await model.provision('Lab', 'example123');
    expect(model.credentialsAcknowledged, true);
  });
  provisioningTest(
      'active cancellation stops further fragments and never commits',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    final blocked = Completer<void>();
    fake.onWrite = (uuid, bytes) async {
      if (uuid == provisioningControl)
        fake.acknowledge(bytes);
      else {
        await blocked.future;
      }
    };
    final pending = model.provision('LabWiFi', 'example123');
    await tester.pump();
    expect(model.phase, ProvisioningPhase.sendingCredentials);
    await model.cancel();
    blocked.complete();
    await pending;
    expect(model.phase, ProvisioningPhase.cancelled);
    expect(fake.writes.where((b) => b.length == 4).map((b) => b[1]), [3, 6]);
    expect(fake.writes.where((b) => b.length > 4).length, 1);
  });
  provisioningTest(
      'cancel while waiting for BEGIN acknowledgement does not consume CANCEL ACK as BEGIN',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    fake.onWrite = (uuid, bytes) async {
      if (uuid == provisioningControl && bytes[1] == 6) fake.acknowledge(bytes);
    };
    final pending = model.provision('Lab', 'example123');
    await tester.pump();
    await model.cancel();
    await pending;
    expect(model.phase, ProvisioningPhase.cancelled);
    expect(fake.writes.map((b) => b[1]), [3, 6]);
  });
  provisioningTest(
      'stop waiting after COMMIT does not send CANCEL or roll back saved credentials',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    await model.provision('Lab', 'example123');
    final count = fake.writes.length;
    await model.cancel();
    expect(fake.writes.length, count);
    expect(model.message, contains('already saved'));
  });
  provisioningTest(
      'disconnect before ACK interrupts without commit or credential resend',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    fake.onWrite = (_, __) async {};
    final pending = model.provision('Lab', 'example123');
    await tester.pump();
    fake.disconnected.add(null);
    await pending;
    expect(model.phase, ProvisioningPhase.disconnected);
    expect(model.message, contains('before acknowledgement'));
    expect(fake.writes.length, 1);
  });
  provisioningTest(
      'disconnect after acknowledged COMMIT reports unknown outcome without resend',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    await model.provision('Lab', 'example123');
    final count = fake.writes.length;
    fake.disconnected.add(null);
    expect(model.message, contains('Wi-Fi may still connect'));
    expect(fake.writes.length, count);
    expect(model.available, false);
  });
  provisioningTest('unencrypted links block credentials and forget',
      (tester) async {
    final fake = FakeProvisioning()..status[2] = 0;
    final model = await setup(fake);
    await model.provision('Lab', 'example123');
    expect(fake.writes, isEmpty);
    expect(model.message, contains('encrypted BLE'));
    await model.forget();
    expect(fake.writes, isEmpty);
    fake.status[2] = 8;
    await model.provision('Lab', 'example123');
    expect(model.credentialsAcknowledged, true);
  });
  provisioningTest(
      'security is rechecked before COMMIT and all mutable credential writes are wiped',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    final references = <List<int>>[];
    fake.onWrite = (uuid, bytes) async {
      if (uuid == provisioningControl)
        fake.acknowledge(bytes);
      else {
        references.add(bytes);
        fake.status[2] = 0;
      }
    };
    await model.provision('Lab', 'example123');
    expect(fake.writes.where((b) => b.length == 4).map((b) => b[1]), [3, 6]);
    expect(references.every((b) => b.every((byte) => byte == 0)), true);
  });
  provisioningTest(
      'open networks always send an empty password and secured networks require one',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    model.networks['Open'] = WifiNetwork('Open', -40, 0);
    await model.provision('Open', 'must-not-be-sent');
    expect(fake.writes.where((b) => b.length > 4).expand((b) => b.skip(7)),
        credentialObject('Open', ''));
    await model.cancel();
    final count = fake.writes.length;
    model.networks['Secure'] = WifiNetwork('Secure', -40, 3);
    await model.provision('Secure', '');
    expect(fake.writes.length, count);
    expect(model.message, contains('secured network'));
  });
  provisioningTest(
      'terminal notifications arriving during COMMIT are retained until ACK',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    fake.onWrite = (uuid, bytes) async {
      if (uuid != provisioningControl) return;
      if (bytes[1] == 4) {
        fake.reportStatus([1, 1, 9, 0, 0, 0, 0, 0]);
        fake.reportStatus([1, 2, 9, 0, 192, 168, 1, 42]);
      }
      fake.acknowledge(bytes);
    };
    await model.provision('Lab', 'example123');
    expect(model.phase, ProvisioningPhase.connected);
  });
  provisioningTest(
      'an old connected or failed status cannot complete a new attempt',
      (tester) async {
    final fake = FakeProvisioning()..status = [1, 2, 9, 0, 192, 168, 1, 5];
    final model = await setup(fake);
    await model.provision('New', 'example123');
    expect(model.phase, ProvisioningPhase.connectingToWifi);
    fake.reportStatus([1, 3, 9, 10, 0, 0, 0, 0]);
    expect(model.phase, ProvisioningPhase.connectingToWifi);
    fake.reportStatus([1, 1, 9, 0, 0, 0, 0, 0]);
    fake.reportStatus([1, 3, 9, 8, 0, 0, 0, 0]);
    expect(model.message, contains('Invalid password'));
    await model.provision('New', 'correct123');
    expect(model.phase, ProvisioningPhase.connectingToWifi);
  });
  provisioningTest('polling reads status if final notification is missed',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    await model.provision('Lab', 'example123');
    fake.reportStatus([1, 1, 9, 0, 0, 0, 0, 0]);
    fake.status = [1, 2, 9, 0, 192, 168, 1, 42];
    await tester.pump(const Duration(seconds: 2));
    expect(model.phase, ProvisioningPhase.connected);
  });
  provisioningTest(
      'connection deadline allows status refresh without replaying credentials',
      (tester) async {
    final fake = FakeProvisioning(),
        model =
            await setup(fake, connectionTimeout: const Duration(seconds: 1));
    await model.provision('Lab', 'example123');
    await tester.pump(const Duration(seconds: 1));
    expect(model.message, contains('Connection status timed out'));
    final count = fake.writes.length;
    fake.status = [1, 2, 9, 0, 192, 168, 1, 42];
    await model.refresh();
    expect(model.phase, ProvisioningPhase.connected);
    expect(fake.writes.length, count);
  });
  provisioningTest(
      'firmware connection timeout is separate from general failure and raw errors are hidden',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    await model.provision('Lab', 'example123');
    fake.reportStatus([1, 1, 9, 0, 0, 0, 0, 0]);
    fake.reportStatus([1, 3, 9, 11, 0, 0, 0, 0]);
    expect(model.message, contains('Wi-Fi connection timed out'));
    fake.onRead = () async => throw StateError('raw platform arguments SECRET');
    await model.refresh();
    expect(model.message, isNot(contains('SECRET')));
    expect(model.message, contains('Reconnect and retry'));
  });
  provisioningTest(
      'disconnect immediately after COMMIT ACK preserves acknowledged outcome',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    fake.onWrite = (uuid, bytes) async {
      if (uuid != provisioningControl) return;
      fake.acknowledge(bytes);
      if (bytes[1] == 4) fake.disconnected.add(null);
    };
    await model.provision('Lab', 'example123');
    expect(model.credentialsAcknowledged, true);
    expect(model.phase, ProvisioningPhase.disconnected);
    expect(model.message, contains('after credentials were acknowledged'));
    expect(fake.writes.where((b) => b.length == 4).map((b) => b[1]), [3, 4]);
  });
  provisioningTest(
      'CANCEL acknowledgement failure does not promise staged credentials were cleared',
      (tester) async {
    final fake = FakeProvisioning(),
        model = await setup(fake, commandTimeout: const Duration(seconds: 1));
    fake.onWrite = (_, __) async {};
    final pending = model.provision('Lab', 'example123');
    await tester.pump();
    final cancellation = model.cancel();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await cancellation;
    await pending;
    expect(model.message, contains('cancellation was not confirmed'));
    expect(model.message, contains('staging expires after 60 seconds'));
  });
  provisioningTest('cancel after sending COMMIT reports unknown save outcome',
      (tester) async {
    final fake = FakeProvisioning(), model = await setup(fake);
    fake.onWrite = (uuid, bytes) async {
      if (uuid == provisioningControl && bytes[1] != 4) fake.acknowledge(bytes);
    };
    final pending = model.provision('Lab', 'example123');
    await tester.pump();
    expect(fake.writes.last[1], 4);
    await model.cancel();
    await pending;
    expect(model.message, contains('COMMIT was already sent'));
    expect(model.message, contains('credentials may be saved'));
    final count = fake.writes.length;
    await model.cancel();
    expect(fake.writes.length, count);
  });
}
