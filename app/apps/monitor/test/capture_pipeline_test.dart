import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/buffered_capture.dart';
import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/file_capture_journal.dart';

Map<String, dynamic> frame(int n) => {
      'frameId': '$n',
      'recordedAt':
          DateTime.fromMillisecondsSinceEpoch(n, isUtc: true).toIso8601String(),
      'channels': List.filled(16, 1.0),
    };

void main() {
  test(
      'receiving persists pages while an upload is blocked; overlapping flush joins',
      () async {
    final uploadGate = Completer<void>();
    final uploadStarted = Completer<void>();
    var requests = 0, cursor = 0;
    final api = Api(client: MockClient((request) async {
      if (request.method == 'POST') {
        requests++;
        uploadStarted.complete();
        await uploadGate.future;
        return http.Response('{}', 201);
      }
      cursor += 1000;
      return http.Response(
          jsonEncode({
            'streamId': 'stream',
            'frames': List.generate(1000, (i) => frame(cursor - 1000 + i)),
            'nextCursor': cursor,
            'missedFrames': 0,
            'hasMore': false
          }),
          200);
    }));
    String? disk;
    final log = CaptureLog(
        read: () async => disk,
        write: (s) async {
          disk = s;
        });
    final capture = BufferedCapture(api, log)
      ..start('session', '127.0.0.1', 0, 'stream');
    await capture.pump();
    final upload = log.flush(api);
    await uploadStarted.future;
    final joined = log.flush(api);
    for (var i = 0; i < 12; i++) {
      await capture.pump();
    }
    expect(capture.saved, 13000);
    expect(capture.cursor, 13000);
    final restored = CaptureLog(read: () async => disk, write: (_) async {});
    await restored.load();
    expect(restored.pending, 13000);
    uploadGate.complete();
    expect(await upload, 1000);
    expect(await joined, 1000);
    expect(requests, 1);
    expect(log.pending, 12000);
    api.close();
  });

  test('failed acknowledgement commit keeps successful upload retryable',
      () async {
    var fail = false, requests = 0;
    String? disk;
    final log = CaptureLog(
        read: () async => disk,
        write: (s) async {
          if (fail) throw StateError('full disk');
          disk = s;
        });
    await log.append(Api.defaultUrl, 's', frame(1));
    final api = Api(client: MockClient((_) async {
      requests++;
      return http.Response('{}', 201);
    }));
    fail = true;
    await expectLater(log.flush(api), throwsStateError);
    expect(log.pending, 1);
    expect(jsonDecode(disk!)[0]['uploaded'], false);
    fail = false;
    expect(await log.flush(api), 1);
    expect(requests, 2);
    api.close();
  });

  test(
      'failed page save retains cursor and rejects malformed samples without skipping',
      () async {
    var fail = true, invalid = false;
    final api = Api(
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'streamId': 'stream',
              'frames': [
                invalid ? {...frame(1), 'channels': []} : frame(1)
              ],
              'nextCursor': 1,
              'hasMore': false
            }),
            200)));
    final log = CaptureLog(
        read: () async => null,
        write: (_) async {
          if (fail) throw StateError('disk unavailable');
        });
    final capture = BufferedCapture(api, log)
      ..start('s', '127.0.0.1', 0, 'stream');
    await expectLater(capture.pump(), throwsStateError);
    expect(capture.cursor, 0);
    fail = false;
    invalid = true;
    await expectLater(capture.pump(), throwsStateError);
    expect(capture.cursor, 0);
    invalid = false;
    await capture.pump();
    expect(capture.cursor, 1);
    expect(log.pending, 1);
    capture.stop();
    await capture.pump();
    expect(log.pending, 1);
    api.close();
  });

  test(
      'native journal session removal survives restart and later acknowledgements',
      () async {
    final directory = await Directory.systemTemp.createTemp('capstone-delete-');
    try {
      final journal = FileCaptureJournal(() async => directory);
      final log = CaptureLog(read: journal.read, operation: journal.append);
      await log.append(Api.defaultUrl, 'remove', frame(1));
      await log.append(Api.defaultUrl, 'keep', frame(2),
          ownerUsername: 'KennyNguyen');
      await log.append('http://another-api', 'remove', frame(3),
          ownerUsername: 'WillAdcox');
      await log.discardSession(Api.defaultUrl, 'remove');
      final restored =
          CaptureLog(read: journal.read, operation: journal.append);
      await restored.load();
      expect(restored.entries.map((e) => e['frameId']), ['2', '3']);
      expect(restored.entries.map((e) => e['ownerUsername']),
          ['KennyNguyen', 'WillAdcox']);
      expect(restored.pending, 2);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
      'native journal migrates, compacts and recovers a torn append with all pending frames',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('capstone-journal-');
    try {
      await File('${directory.path}/capstone-log.json')
          .writeAsString(jsonEncode([
        {
          ...frame(0),
          'apiUrl': Api.defaultUrl,
          'sessionId': 's',
          'uploaded': false
        }
      ]));
      final journal =
          FileCaptureJournal(() async => directory, compactBytes: 1500);
      final log = CaptureLog(read: journal.read, operation: journal.append);
      await log.load();
      await log.appendAll(
          Api.defaultUrl, 's', List.generate(1000, (i) => frame(i + 1)));
      final api =
          Api(client: MockClient((_) async => http.Response('{}', 201)));
      await log.flush(api);
      await log.appendAll(
          Api.defaultUrl, 's', List.generate(1000, (i) => frame(i + 1001)));
      await File('${directory.path}/capstone-capture-v2.jsonl')
          .writeAsString('{"add":[', mode: FileMode.append);
      final restored =
          CaptureLog(read: journal.read, operation: journal.append);
      await restored.load();
      expect(restored.pending, 1000);
      expect(restored.entries.length, 1500);
      await restored.append(Api.defaultUrl, 's', frame(2001));
      await restored.load();
      expect(restored.pending, 1001);
      api.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
