import 'dart:math';
import 'api.dart';
import 'capture_log.dart';
import 'device_packets.dart';

/// Native transports share the existing save-before-upload path. Notification
/// callbacks enqueue synchronously; only one drain can touch the durable log.
class DirectCapture {
  final Api api;
  final CaptureLog log;
  final List<Map<String, dynamic>> _pending = [];
  final String _epoch =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  String? sessionId;
  String? _owner, _destination;
  bool capturing = false;
  int received = 0, invalid = 0, duplicates = 0, uploaded = 0, overflow = 0;
  int _lastUs = 0;
  int? _clockOffsetUs, _lastDeviceUs;
  String? _lastKey;
  DeviceSample? latest;
  DateTime? receivedAt;
  Future<void>? _draining;
  DirectCapture(this.api, this.log);
  int get queued => _pending.length;

  void add(DeviceSample sample) {
    received++;
    receivedAt = DateTime.now();
    latest = sample;
    final key = '${sample.sequence}:${sample.timestampUs}';
    if (key == _lastKey) {
      duplicates++;
      return;
    }
    _lastKey = key;
    if (sample.channels.length != 16 ||
        sample.channels.any((v) => !v.isFinite || v < -5 || v > 5)) {
      invalid++;
      return;
    }
    if (!capturing || sessionId == null) return;
    if (api.username != _owner || api.baseUrl != _destination) {
      stop();
      return;
    }
    if (_pending.length >= 10000) {
      overflow++;
      capturing = false;
      return;
    }
    // Keep device sub-ms timing even when notifications arrive in a burst.
    // A decreasing device clock denotes a reset; keep SQL keys monotonic.
    if (_lastDeviceUs != null && sample.timestampUs < _lastDeviceUs!) {
      _clockOffsetUs = null;
    }
    _clockOffsetUs ??= max(
        receivedAt!.microsecondsSinceEpoch - sample.timestampUs,
        _lastUs + 1 - sample.timestampUs);
    _lastDeviceUs = sample.timestampUs;
    _lastUs = max(_lastUs + 1, _clockOffsetUs! + sample.timestampUs);
    _pending.add({
      'frameId': '$_epoch-$_lastUs-$key',
      'recordedAt': DateTime.fromMicrosecondsSinceEpoch(_lastUs, isUtc: true)
          .toIso8601String(),
      'channels': sample.channels,
    });
  }

  void start(String id) {
    if (api.authenticationRequired && !api.signedIn) {
      throw StateError('Sign in before starting capture.');
    }
    if (_pending.isNotEmpty || _draining != null) {
      throw StateError('Wait for pending frames to be saved first.');
    }
    sessionId = id;
    _owner = api.username;
    _destination = api.baseUrl;
    _clockOffsetUs = null;
    _lastDeviceUs = null;
    capturing = true;
  }

  void stop() {
    capturing = false;
  }

  void clearLive() {
    latest = null;
    receivedAt = null;
    _lastKey = null;
  }

  Future<void>? _uploading;
  Future<void> get uploadsIdle => _uploading ?? Future.value();

  Future<void> uploadPending() {
    if (_uploading != null) return _uploading!;
    final operation = _upload();
    _uploading = operation;
    return operation.whenComplete(() {
      _uploading = null;
    });
  }

  Future<void> _upload() async {
    uploaded += await log.flush(api);
  }

  Future<void> drain({bool upload = true}) async {
    if (_draining != null) {
      await _draining;
    } else {
      final operation = _savePending();
      _draining = operation;
      try {
        await operation;
      } finally {
        _draining = null;
      }
    }
    if (upload) await uploadPending();
  }

  Future<void> _savePending() async {
    // Bound each turn but persist multiple pages without waiting for uploads.
    for (var page = 0; page < 8 && _pending.isNotEmpty; page++) {
      final batch = _pending.take(1000).toList();
      await log.appendAll(_destination!, sessionId!, batch,
          ownerUsername: _owner);
      _pending.removeRange(0, batch.length);
    }
  }
}
