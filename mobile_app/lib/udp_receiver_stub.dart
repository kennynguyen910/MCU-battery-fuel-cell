import 'device_packets.dart';

class NativeUdpReceiver {
  NativeUdpReceiver(
      {required void Function(List<DeviceSample>, String) onSample,
      required void Function(Object) onError});
  bool get active => false;
  int get port => 5005;
  int datagrams = 0, invalid = 0, ignored = 0;
  String? sourceIp;
  Future<void> start({int port = 5005}) async {
    throw UnsupportedError('UDP collection requires the native Android app.');
  }

  Future<void> close() async {}
}
