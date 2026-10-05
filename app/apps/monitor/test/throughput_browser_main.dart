import 'dart:convert';
import 'package:http/http.dart' as http;
import 'support/throughput_check.dart';

// Built as a standalone Flutter web entry point by the test runner. It uses
// production collectors/storage and never ships in the normal app entry points.
Future<void> main() async {
  const url = String.fromEnvironment('THROUGHPUT_URL');
  Map<String, dynamic> result;
  try {
    result = {'ok': true, 'result': await runThroughputAcceptance(url)};
  } catch (error, stack) {
    result = {'ok': false, 'error': '$error', 'stack': '$stack'};
  }
  await http.post(Uri.parse('$url/test/result'),
      headers: {'Content-Type': 'application/json'}, body: jsonEncode(result));
}
