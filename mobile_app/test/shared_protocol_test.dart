import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:capstone_monitor/device_packets.dart';
import 'package:capstone_monitor/wifi_protocol.dart';

void main() {
  final fixture =
      jsonDecode(File('../contracts/protocol-v1.json').readAsStringSync())
          as Map<String, dynamic>;
  List<int> bytes(String value) => List.generate(value.length ~/ 2,
      (i) => int.parse(value.substring(i * 2, i * 2 + 2), radix: 16));
  void verify(DeviceSample frame, Map<String, dynamic> expected) {
    expect(frame.sequence, expected['sequence']);
    expect(frame.timestampUs.toString(), expected['timestampUs']);
    expect(frame.status, expected['status']);
    expect(
        frame.channels,
        (expected['channelsUv'] as List)
            .map((value) => value / 1000000)
            .toList());
  }

  test('mobile BLE and USB decode the same C++ golden measurement', () {
    for (final sample in [
      fixture['firmwareGolden'],
      ...fixture['benchSamples']
    ]) {
      verify(decodeBleVoltage(bytes(sample['bleHex'])),
          Map<String, dynamic>.from(sample));
      verify(decodeUsbMeasurement(bytes(sample['udpHex'])),
          Map<String, dynamic>.from(sample));
    }
  });
  test('fragmented USB console data decodes the shared bench measurement', () {
    final sample = fixture['benchSamples'][0];
    final line = utf8.encode('BMHEX:${sample['udpHex']}\n');
    final parser = UsbMeasurementLines();
    expect(parser.add(line.sublist(0, 23)), isEmpty);
    final frames = parser.add(line.sublist(23));
    verify(frames.single, Map<String, dynamic>.from(sample));
  });
  test(
      'client provisioning UUIDs, scan reassembly and credentials match the shared contract',
      () {
    final provision = fixture['provisioning'];
    expect(provisioningService, provision['service']);
    expect(provisioningControl, provision['control']);
    expect(provisioningData, provision['data']);
    expect(provisioningStatus, provision['status']);
    final status = WifiStatus.decode(bytes(provision['connectedStatusHex']));
    expect(status.state, 2);
    expect(status.ip, '192.168.1.42');
    expect(status.encrypted, true);
    final objects = ProvisioningObjects();
    List<int>? complete;
    for (final packet in provision['scanFragmentsHex']) {
      complete = objects.add(bytes(packet), 0x17);
    }
    final network = WifiNetwork.decode(complete!);
    expect(network.ssid, provision['scanSsid']);
    expect(network.rssi, provision['scanRssi']);
    expect(network.auth, provision['scanAuth']);
    expect(credentialObject('LabWiFi', 'example123'),
        bytes(provision['credentialsObjectHex']));
    expect(
        credentialFragments(0x18, credentialObject('LabWiFi', 'example123'))
            .toList(),
        (provision['credentialsFragmentsHex'] as List)
            .map((packet) => bytes(packet))
            .toList());
  });
}
