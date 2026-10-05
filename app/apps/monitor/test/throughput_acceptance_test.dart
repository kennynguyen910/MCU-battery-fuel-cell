import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'support/throughput_check.dart';

void main() {
  const url = String.fromEnvironment('THROUGHPUT_URL');
  if (url.isEmpty) return;
  test('sustained wire-rate capture and configured recovery scenarios',
      () async {
    final result = await runThroughputAcceptance(url);
    print('DART_THROUGHPUT_RESULT ${jsonEncode(result)}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
