// Browser capture uses an IndexedDB journal, including legacy log migration.

import 'dart:convert';
import 'browser_capture_journal.dart';

const journalSupported = true;
final _journal = BrowserCaptureJournal('$key-v2', legacyKey: key);
Future<void> appendLogOperation(
        Map<String, dynamic> operation, List<Map<String, dynamic>> snapshot) =>
    _journal.append(operation, snapshot);

// Version the key so a future incompatible log format can migrate explicitly.
String get key {
  final params = Uri.base.queryParameters;
  final run = params['run'];
  if (params['demo'] == '1' &&
      run != null &&
      RegExp(r'^[a-zA-Z0-9-]{1,64}$').hasMatch(run)) {
    return 'capstone-demo-log-$run';
  }
  return 'capstone-capture-log-v1';
}

Future<String?> readLog() => _journal.read();
Future<void> writeLog(String data) =>
    _journal.replace((jsonDecode(data) as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList());
