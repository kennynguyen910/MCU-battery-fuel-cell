import 'dart:async';
import 'dart:convert';
import 'package:capstone_monitor/wifi_protocol.dart';
import 'package:capstone_monitor/wifi_transport.dart';

class FakeProvisioning extends ProvisioningTransport {
  final notifications = {
    for (final uuid in [
      provisioningControl,
      provisioningData,
      provisioningStatus
    ])
      uuid: StreamController<List<int>>.broadcast(sync: true)
  };
  final disconnected = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get disconnections => disconnected.stream;
  Future<List<int>> Function()? onRead;
  final writes = <List<int>>[];
  List<int> status = [1, 0, 8, 0, 0, 0, 0, 0];
  bool noService = false;
  int? reject;
  Future<void> Function(String, List<int>)? onWrite;
  @override
  Future<void> discover() async {
    if (noService)
      throw const ProvisioningFailure('Firmware missing provisioning service');
  }

  @override
  Stream<List<int>> subscribe(String characteristic) =>
      notifications[characteristic]!.stream;
  @override
  Future<List<int>> readStatus() async =>
      onRead == null ? List.of(status) : await onRead!();
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

  void acknowledge(List<int> command,
      {int? opcode, int? transaction, int error = 0}) {
    notifications[provisioningControl]!.add([
      1,
      error == 0 ? 0x80 : 0x81,
      transaction ?? command[2],
      2,
      opcode ?? command[1],
      error
    ]);
  }

  void reportStatus(List<int> value) {
    status = List.of(value);
    notifications[provisioningStatus]!.add(value);
  }

  void network(String ssid,
      {int transaction = 0, int index = 0, int rssi = -48, int auth = 3}) {
    final name = utf8.encode(ssid);
    final object = [index, rssi & 255, auth, name.length, ...name];
    for (var offset = 0; offset < object.length; offset += 13) {
      final chunk =
          object.sublist(offset, (offset + 13).clamp(0, object.length));
      notifications[provisioningData]!.add([
        1,
        2,
        transaction,
        index,
        offset,
        object.length,
        chunk.length,
        ...chunk
      ]);
    }
  }

  void scanDone(int transaction, int count) {
    notifications[provisioningControl]!.add([1, 0x82, transaction, 1, count]);
  }

  Future<void> close() async {
    await disconnected.close();
    for (final controller in notifications.values) {
      await controller.close();
    }
  }
}
