import 'dart:convert';
import 'dart:io';

import 'capture_journal_codec.dart';

/// Flush only new data, compact by atomic replacement. CaptureLog serializes
/// calls. Recovery trims a torn final record; corrupt complete records fail
/// closed instead of silently losing data.
class FileCaptureJournal {
  final Future<Directory> Function() directory;
  final int compactBytes;
  FileCaptureJournal(this.directory, {this.compactBytes = 32 * 1024 * 1024});
  Future<File> _file() async =>
      File('${(await directory()).path}/capstone-capture-v2.jsonl');

  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) {
      final legacy = File('${file.parent.path}/capstone-log.json');
      if (!await legacy.exists()) return null;
      final data = await legacy.readAsString();
      await _replace(file, {'snapshot': jsonDecode(data)});
      return data;
    }
    final bytes = await file.readAsBytes();
    final end = bytes.lastIndexOf(10) + 1;
    if (end != bytes.length) {
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.truncate(end);
        await handle.flush();
      } finally {
        await handle.close();
      }
    }
    final replay = CaptureJournalReplay();
    for (final line in utf8.decode(bytes.sublist(0, end)).split('\n')) {
      if (line.isNotEmpty) replay.apply(line);
    }
    return replay.json;
  }

  Future<void> _replace(File file, Map<String, dynamic> op) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString('${jsonEncode(op)}\n', flush: true);
    await temporary.rename(file.path);
  }

  Future<void> append(
      Map<String, dynamic> op, List<Map<String, dynamic>> snapshot) async {
    final file = await _file();
    final handle = await file.open(mode: FileMode.append);
    final originalLength = await handle.length();
    try {
      await handle.writeString('${jsonEncode(op)}\n');
      await handle.flush();
    } catch (_) {
      await handle.truncate(originalLength);
      await handle.flush();
      rethrow;
    } finally {
      await handle.close();
    }
    // Append is durable; failed compaction cannot undo that acknowledgement.
    if (await file.length() >= compactBytes) {
      try {
        await _replace(file, {'snapshot': snapshot});
      } on FileSystemException {/* Retry on the next append. */}
    }
  }
}
