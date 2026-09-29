// Browser preview implementation. localStorage gives the demo restart behavior
// without pretending that a browser has the native app's documents directory.
import 'package:web/web.dart' as web;

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

Future<String?> readLog() async => web.window.localStorage.getItem(key);
Future<void> writeLog(String data) async =>
    web.window.localStorage.setItem(key, data);
