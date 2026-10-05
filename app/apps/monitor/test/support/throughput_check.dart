import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/buffered_capture.dart';
import 'throughput_storage_io.dart'
    if (dart.library.js_interop) 'throughput_storage_web.dart' as storage;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<Map<String, dynamic>> runThroughputAcceptance(String url) async {
  final harness = await storage.createLogHarness();
  final client = http.Client();
  final api = Api(baseUrl: url);
  try {
    final config =
        jsonDecode((await client.get(Uri.parse('$url/test/config'))).body)
            as Map;
    final expected = config['frames'] as int;
    var log = harness.open();
    await log.load();
    var capture = BufferedCapture(api, log);
    // There are no earlier packets; the stream UUID appears with the first packet.
    await client.post(Uri.parse('$url/test/start'));
    Map<String, dynamic> baseline;
    do {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      baseline = await api.deviceFrames(sourceIp: '127.0.0.1');
    } while (baseline['streamId'] == null);
    capture.start(config['sessionId'] as String, '127.0.0.1', 0,
        baseline['streamId'] as String);
    var saving = false,
        uploading = false,
        maxPending = 0,
        outages = 0,
        reloaded = false,
        reloading = false;
    Object? saveError;
    Future<void> save() async {
      if (saving || reloading) return;
      saving = true;
      try {
        await capture.pump();
        maxPending = maxPending > log.pending ? maxPending : log.pending;
      } catch (error) {
        saveError = error;
      } finally {
        saving = false;
      }
    }

    Future<void> upload() async {
      if (uploading || reloading) return;
      uploading = true;
      try {
        await log.flush(api);
      } on ApiException catch (error) {
        if (error.statusCode == 503) {
          outages++;
        } else {
          saveError = error;
        }
      } catch (error) {
        saveError = error;
      } finally {
        uploading = false;
      }
    }

    final receiveTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) => save());
    final uploadTimer =
        Timer.periodic(const Duration(milliseconds: 500), (_) => upload());
    final deadline = DateTime.now()
        .add(Duration(seconds: expected ~/ (config['fps'] as int) + 90));
    var savedBeforeReload = 0;
    try {
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (saveError != null) throw saveError!;
        check(capture.missed == 0, 'Reader buffer loss');
        // Recover while the backlog is present, using the real on-disk journal.
        if (!reloaded && outages >= 3) {
          reloading = true;
          while (saving || uploading) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          reloaded = true;
          savedBeforeReload = capture.saved;
          final cursor = capture.cursor!;
          capture.stop();
          log = harness.open();
          await log.load();
          capture = BufferedCapture(api, log)
            ..start(config['sessionId'] as String, '127.0.0.1', cursor,
                baseline['streamId'] as String);
          reloading = false;
        }
        final status =
            jsonDecode((await client.get(Uri.parse('$url/test/status'))).body)
                as Map;
        if (status['producer'] != null &&
            savedBeforeReload + capture.saved == expected &&
            log.pending == 0 &&
            !saving &&
            !uploading) break;
        if (DateTime.now().isAfter(deadline))
          throw StateError(
              'Capture failed to drain at wire rate: saved=${savedBeforeReload + capture.saved}/$expected pending=${log.pending}');
      }
    } finally {
      receiveTimer.cancel();
      uploadTimer.cancel();
      while (saving || uploading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      capture.stop();
    }
    check(reloaded, 'Journal reload scenario did not run');
    check(outages > 0, 'Upload outage did not run');
    check(capture.missed == 0, 'Reader buffer loss');
    final restored = harness.open();
    await restored.load();
    check(restored.pending == 0, 'Recovery left pending frames');
    return {
      'frames': expected,
      'missed': capture.missed,
      'maxPending': maxPending,
      'uploadFailures': outages,
      'restartRecovered': reloaded
    };
  } finally {
    api.close();
    client.close();
    await harness.cleanup();
  }
}
