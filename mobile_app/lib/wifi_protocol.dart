import 'dart:convert';

const provisioningService = '5ecf1000-41c2-4cc4-9c96-640f406021d0';
const provisioningControl = '5ecf1001-41c2-4cc4-9c96-640f406021d0';
const provisioningData = '5ecf1002-41c2-4cc4-9c96-640f406021d0';
const provisioningStatus = '5ecf1003-41c2-4cc4-9c96-640f406021d0';

class WifiStatus {
  final int state, flags, error;
  final String ip;
  WifiStatus(this.state, this.flags, this.error, this.ip);
  bool get credentialsStored => flags & 1 != 0;
  bool get encrypted => flags & 8 != 0;
  String get label =>
      ['Unprovisioned', 'Connecting', 'Connected', 'Connection failed'][state];
  factory WifiStatus.decode(List<int> bytes) {
    if (bytes.length != 8 || bytes[0] != 1 || bytes[1] > 3) {
      throw const FormatException('Invalid Wi-Fi status or protocol version');
    }
    return WifiStatus(bytes[1], bytes[2], bytes[3], bytes.sublist(4).join('.'));
  }
}

class WifiNetwork {
  final String ssid;
  final int rssi, auth;
  WifiNetwork(this.ssid, this.rssi, this.auth);
  bool get supported => [0, 3, 5, 6].contains(auth);
  factory WifiNetwork.decode(List<int> bytes) {
    if (bytes.length < 4 || bytes[3] > 32 || bytes.length != 4 + bytes[3]) {
      throw const FormatException('Invalid scan result');
    }
    return WifiNetwork(utf8.decode(bytes.sublist(4)),
        bytes[1] >= 128 ? bytes[1] - 256 : bytes[1], bytes[2]);
  }
}

List<int> credentialObject(String ssid, String password) {
  final name = utf8.encode(ssid), secret = utf8.encode(password);
  try {
    if (name.length > 32)
      throw const FormatException('SSID must contain at most 32 UTF-8 bytes');
    if (secret.length > 63)
      throw const FormatException(
          'Password must contain at most 63 UTF-8 bytes');
    return [name.length, secret.length, ...name, ...secret];
  } finally {
    // The returned object is wiped by its owner; clear temporary UTF-8 copies too.
    secret.fillRange(0, secret.length, 0);
  }
}

Iterable<List<int>> credentialFragments(
    int transaction, List<int> object) sync* {
  if (transaction < 1 || transaction > 255 || object.length > 97) {
    throw const FormatException('Invalid credential transaction');
  }
  for (var offset = 0; offset < object.length; offset += 13) {
    yield [
      1,
      1,
      transaction,
      0,
      offset,
      object.length,
      (object.length - offset).clamp(0, 13),
      ...object.sublist(offset, (offset + 13).clamp(0, object.length))
    ];
  }
}

/// One bounded object per key, with an absolute lifetime and strict overlap checks.
class ProvisioningObjects {
  final _objects = <String, _Object>{};
  void clear() => _objects.clear();
  List<int>? add(List<int> packet, int transaction, {DateTime? now}) {
    final time = now ?? DateTime.now();
    _objects.removeWhere(
        (_, value) => time.difference(value.started).inSeconds >= 60);
    if (packet.length < 7 ||
        packet[0] != 1 ||
        ![2, 3].contains(packet[1]) ||
        packet[2] != transaction ||
        packet[5] == 0 ||
        packet[5] > (packet[1] == 2 ? 36 : 38) ||
        packet[6] == 0 ||
        packet.length != 7 + packet[6] ||
        packet[4] + packet[6] > packet[5]) {
      throw const FormatException('Invalid provisioning fragment');
    }
    final key = '${packet[1]}:${packet[2]}:${packet[3]}';
    final object = _objects.putIfAbsent(key, () => _Object(packet[5], time));
    if (object.bytes.length != packet[5]) {
      _objects.remove(key);
      throw const FormatException('Fragment length changed');
    }
    for (var i = 0; i < packet[6]; i++) {
      final index = packet[4] + i, byte = packet[7 + i];
      if (object.bytes[index] != null && object.bytes[index] != byte) {
        _objects.remove(key);
        throw const FormatException('Conflicting fragment');
      }
      object.bytes[index] = byte;
    }
    if (object.bytes.any((byte) => byte == null)) return null;
    _objects.remove(key);
    return object.bytes.cast<int>();
  }
}

class _Object {
  final List<int?> bytes;
  final DateTime started;
  _Object(int length, this.started) : bytes = List.filled(length, null);
}

String provisioningError(int code) => switch (code) {
      1 => 'Unsupported protocol version.',
      4 => 'Device is busy. Retry shortly.',
      5 => 'Pair using an encrypted BLE connection before changing Wi-Fi.',
      6 => 'Network scan failed. Try again.',
      7 => 'Invalid network name.',
      8 => 'Invalid password. Edit it and retry.',
      9 => 'Device could not save the network.',
      10 =>
        'Unable to connect. Check the password and network availability, then retry. The device did not report a more specific cause.',
      11 =>
        'Wi-Fi connection timed out. Check that the network is available, then retry.',
      12 || 13 || 14 => 'Provisioning transaction failed. Start again.',
      _ => 'Device rejected the operation (code $code).',
    };
