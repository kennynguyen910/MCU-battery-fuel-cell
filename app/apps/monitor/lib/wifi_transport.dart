import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'wifi_protocol.dart';

/// Small transport boundary so the byte protocol can be exercised without a radio.
abstract class ProvisioningTransport {
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
    await ble.discoverAllServices(deviceId);
    final services = await ble.getDiscoveredServices(deviceId);
    final service = services
        .where((service) => service.id == Uuid.parse(provisioningService));
    if (service.isEmpty ||
        ![
          provisioningControl,
          provisioningData,
          provisioningStatus
        ].every((uuid) => service.first.characteristics
            .any((characteristic) => characteristic.id == Uuid.parse(uuid)))) {
      throw StateError(
          'This firmware does not expose Wi-Fi provisioning v1. Install the matching firmware service.');
    }
  }

  @override
  Stream<List<int>> subscribe(String characteristic) =>
      ble.subscribeToCharacteristic(_characteristic(characteristic));
  @override
  Future<List<int>> readStatus() =>
      ble.readCharacteristic(_characteristic(provisioningStatus));
  @override
  Future<void> write(String characteristic, List<int> bytes) async {
    try {
      await ble.writeCharacteristicWithResponse(_characteristic(characteristic),
          value: bytes);
    } catch (_) {
      // Platform error details may include write arguments; never surface them.
      throw StateError('BLE provisioning write failed. Reconnect and retry.');
    }
  }
}
