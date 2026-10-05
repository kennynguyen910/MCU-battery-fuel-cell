import 'api.dart';
import 'capture_log.dart';

/// Independent acquisition pump: cursor advancement follows local durability.
/// Screen refreshes and database uploads cannot delay receiving the next page.
class BufferedCapture {
  final Api api;
  final CaptureLog log;
  BufferedCapture(this.api, this.log);
  String? _session, _source, _stream, _destination;
  String? _owner;
  int? cursor;
  int saved = 0, missed = 0;
  bool active = false;
  Future<void>? _pumping;
  void start(String session, String source, int baseline, String stream) {
    if (api.authenticationRequired && !api.signedIn) {
      throw StateError('Sign in before starting capture.');
    }
    if (_pumping != null)
      throw StateError('Wait for the previous capture page to finish.');
    _session = session;
    _source = source;
    _stream = stream;
    _destination = api.baseUrl;
    _owner = api.username;
    cursor = baseline;
    saved = 0;
    missed = 0;
    active = true;
  }

  void stop() {
    active = false;
  }

  Future<void> get idle => _pumping ?? Future.value();
  Future<void> pump() {
    if (_pumping != null) return _pumping!;
    final task = _pump();
    _pumping = task;
    return task.whenComplete(() {
      _pumping = null;
    });
  }

  Future<void> _pump() async {
    for (var page = 0; page < 8 && active; page++) {
      if (api.baseUrl != _destination || api.username != _owner) {
        stop();
        return;
      }
      final result = await api.deviceFrames(
          sourceIp: _source, afterCursor: cursor, streamId: _stream);
      if (!active) return;
      if (result['streamReset'] == true || result['streamId'] != _stream) {
        stop();
        throw StateError(
            'Receiver restarted. Start capture again to use the new stream.');
      }
      final frames = (result['frames'] as List)
          .map((f) => Map<String, dynamic>.from(f))
          .toList();
      for (final frame in frames) {
        final channels = frame['channels'];
        if (channels is! List ||
            channels.length != 16 ||
            !channels
                .every((v) => v is num && v.isFinite && v >= -5 && v <= 5)) {
          throw StateError(
              'Invalid buffered frame; cursor retained for recovery.');
        }
      }
      await log.appendAll(_destination!, _session!, frames,
          ownerUsername: _owner);
      cursor = result['nextCursor'] as int;
      missed += result['missedFrames'] as int? ?? 0;
      saved += frames.length;
      if (result['hasMore'] != true) return;
    }
  }
}
