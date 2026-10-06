import 'dart:io';
import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/file_capture_journal.dart';

class LogHarness {
  final Directory directory;
  late final journal = FileCaptureJournal(() async => directory);
  LogHarness(this.directory);
  CaptureLog open() =>
      CaptureLog(read: journal.read, operation: journal.append);
  Future<void> cleanup() => directory.delete(recursive: true);
}

Future<LogHarness> createLogHarness() async =>
    LogHarness(await Directory.systemTemp.createTemp('capstone-throughput-'));
