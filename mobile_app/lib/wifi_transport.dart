import 'dart:async';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'wifi_protocol.dart';

/// Safe user-facing error; platform exceptions must not expose write arguments.
class ProvisioningFailure implements Exception {
  final String message;
  const ProvisioningFailure(this.message);
  @override
  String toString() => message;
}

/// Small transport boundary so the byte protocol can be exercised without a radio.
abstract class ProvisioningTransport {
  /// Emits when this device disconnects, independently of characteristic streams.
  Stream<void> get disconnections => const Stream.empty();
  Future<void> discover();
  Stream<List<int>> subscribe(String characteristic);
  Future<List<int>> readStatus();
  Future<void> write(String characteristic, List<int> bytes);
}

class BleProvisioningTransport implements ProvisioningTransport {
  final FlutterReactiveBle ble;
  final String deviceId;
  BleProvisioningTransport(this.ble, this.deviceId);
  QualifiedCharacteristic _characteristic(String uuid) =>
      QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: Uuid.parse(provisioningService),
          characteristicId: Uuid.parse(uuid));
  @override
  Future<void> discover() async {
    try {
      await ble.discoverAllServices(deviceId);
      final services = await ble.getDiscoveredServices(deviceId);
      final service = services
          .where((service) => service.id == Uuid.parse(provisioningService));
      if (service.isEmpty ||
          ![provisioningControl, provisioningData, provisioningStatus].every(
              (uuid) => service.first.characteristics.any(
                  (characteristic) => characteristic.id == Uuid.parse(uuid)))) {
        throw const ProvisioningFailure(
            'This firmware does not expose Wi-Fi provisioning v1. Install the matching firmware service.');
      }
    } on ProvisioningFailure {
      rethrow;
    } catch (_) {
      throw const ProvisioningFailure(
          'Unable to discover Wi-Fi provisioning. Reconnect and retry.');
    }
  }

  @override
  Stream<void> get disconnections => ble.connectedDeviceStream
      .where((update) =>
          update.deviceId == deviceId &&
          update.connectionState == DeviceConnectionState.disconnected)
      .map((_) {});

  @override
  Stream<List<int>> subscribe(String characteristic) =>
      ble.subscribeToCharacteristic(_characteristic(characteristic));
  @override
  Future<List<int>> readStatus() async {
    try {
      return await ble.readCharacteristic(_characteristic(provisioningStatus));
    } catch (_) {
      throw const ProvisioningFailure(
          'Unable to read Wi-Fi status. Reconnect and retry.');
    }
  }

  @override
  Future<void> write(String characteristic, List<int> bytes) async {
    try {
      await ble.writeCharacteristicWithResponse(_characteristic(characteristic),
          value: bytes);
    } catch (_) {
      // Platform error details may include write arguments; never surface them.
      throw const ProvisioningFailure(
          'BLE provisioning write failed. Reconnect and retry.');
    }
  }
}
