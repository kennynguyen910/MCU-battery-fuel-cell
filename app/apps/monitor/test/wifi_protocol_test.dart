import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:capstone_monitor/wifi_protocol.dart';

void main() {
  test('status decodes protocol example and rejects unsupported versions', () {
    final status = WifiStatus.decode([1, 2, 9, 0, 192, 168, 1, 42]);
    expect(status.encrypted, true);
    expect(status.ip, '192.168.1.42');
    expect(() => WifiStatus.decode([2, 2, 0, 0, 0, 0, 0, 0]),
        throwsFormatException);
  });
  test('credentials respect byte limits and default ATT MTU', () {
    final object = credentialObject('LabWiFi', 'example123');
    expect(object.take(2), [7, 10]);
    final packets = credentialFragments(17, object);
    expect(packets.every((packet) => packet.length <= 20), true);
    expect(packets.expand((packet) => packet.skip(7)).toList(), object);
    expect(credentialObject('Open', '')[1], 0);
    expect(() => credentialObject('é' * 17, ''), throwsFormatException);
    expect(() => credentialObject('WiFi', 'x' * 64), throwsFormatException);
  });
  test('scan objects accept out of order and reject conflicting fragments', () {
    final objects = ProvisioningObjects();
    expect(objects.add([1, 2, 4, 0, 2, 4, 2, 3, 0], 4), null);
    final complete = objects.add([1, 2, 4, 0, 0, 4, 2, 0, 208], 4)!;
    expect(WifiNetwork.decode(complete).rssi, -48);
    objects.add([1, 2, 4, 1, 0, 4, 1, 0], 4);
    expect(
        () => objects.add([1, 2, 4, 1, 0, 4, 1, 1], 4), throwsFormatException);
    expect(
        () => objects.add([1, 2, 5, 1, 0, 4, 1, 0], 4), throwsFormatException);
    expect(() => objects.add([1, 2, 4, 1, 3, 4, 2, 0, 0], 4),
        throwsFormatException);
  });
  test('scan parsing validates SSID length and enterprise support', () {
    final name = utf8.encode('Campus');
    expect(
        WifiNetwork.decode([0, 200, 7, name.length, ...name]).supported, false);
    expect(() => WifiNetwork.decode([0, 200, 3, 8, 1]), throwsFormatException);
  });
  test('partial objects expire after 60 seconds', () {
    final objects = ProvisioningObjects(), start = DateTime(2026);
    objects.add([1, 2, 1, 0, 0, 4, 2, 0, 208], 1, now: start);
    expect(
        objects.add([1, 2, 1, 0, 2, 4, 2, 3, 0], 1,
            now: start.add(const Duration(seconds: 61))),
        null);
  });
}
