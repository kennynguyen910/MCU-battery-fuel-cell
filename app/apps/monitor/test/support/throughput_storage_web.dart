import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/browser_capture_journal.dart';

class LogHarness {
  final journal = BrowserCaptureJournal(
      'capstone-throughput-${DateTime.now().microsecondsSinceEpoch}');
  CaptureLog open() =>
      CaptureLog(read: journal.read, operation: journal.append);
  Future<void> cleanup() => journal.delete();
}

Future<LogHarness> createLogHarness() async => LogHarness();
