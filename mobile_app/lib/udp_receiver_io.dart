import 'dart:async';
import 'dart:io';
import 'device_packets.dart';

/// One selected sender per capture. No HTTP relay and no database access.
class NativeUdpReceiver {
  final void Function(List<DeviceSample>, String) onSample;
  final void Function(Object) onError;
  NativeUdpReceiver({required this.onSample, required this.onError});
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  bool get active => _socket != null;
  int get port => _socket?.port ?? 5005;
  int datagrams = 0, invalid = 0, ignored = 0;
  String? sourceIp;
  int _generation = 0;
  Future<void>? _starting;
  Future<void> start({int port = 5005}) {
    if (active) return Future.value();
    if (_starting != null) return _starting!;
    final task = _bind(port, _generation);
    _starting = task;
    return task.whenComplete(() => _starting = null);
  }

  Future<void> _bind(int port, int generation) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port,
        reuseAddress: false);
    if (generation != _generation) {
      socket.close();
      return;
    }
    _socket = socket;
    _subscription = socket.listen((event) {
      if (event == RawSocketEvent.closed) {
        _socket = null;
        onError(StateError('UDP receiver closed. Restart the receiver.'));
        return;
      }
      if (event != RawSocketEvent.read) return;
      // Bound a callback so journal persistence and uploads keep making progress.
      for (var n = 0; n < 32; n++) {
        final packet = socket.receive();
        if (packet == null) break;
        if (sourceIp != null && packet.address.address != sourceIp) {
          ignored++;
          continue;
        }
        datagrams++;
        try {
          final decoded = decodeUdpMeasurements(packet.data);
          invalid += decoded.invalidFrames;
          if (decoded.frames.isEmpty) continue;
          sourceIp ??= packet.address.address;
          onSample(decoded.frames, packet.address.address);
        } on FormatException {
          invalid++;
        }
      }
    }, onError: onError);
  }

  Future<void> close() async {
    _generation++;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    sourceIp = null;
  }
}
