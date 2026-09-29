// Native Android/iOS implementation of the local capture log.
import 'dart:io';
import 'package:path_provider/path_provider.dart';

// path_provider chooses an application-owned documents folder on each platform.
Future<File> _file() async {
  final directory = await getApplicationDocumentsDirectory();
  return File('${directory.path}/capstone-log.json');
}

// A missing file means the app has never captured a frame, not an error.
Future<String?> readLog() async {
  final file = await _file();
  return await file.exists() ? file.readAsString() : null;
}

// Write to a sibling temporary file first so an interrupted write does not leave
// half-valid JSON in the main log.
Future<void> writeLog(String data) async {
  final file = await _file();
  // Replace only after the new JSON has been flushed to disk.
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(data, flush: true);
  await temporary.rename(file.path);
}
