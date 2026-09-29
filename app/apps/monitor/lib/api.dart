// Shared HTTP client for all three Flutter roles. Widgets call small domain
// methods here instead of duplicating URL, JSON, timeout, and error behavior.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);
  @override
  String toString() => message;
}

/// The only place that knows HTTP details. Both screens use this same contract.
/// API_URL must be reachable from the browser/phone, not just the development PC.
class Api {
  /// Browser development uses localhost. Native builds override this value with
  /// --dart-define because a phone/emulator has a different network viewpoint.
  static String get defaultUrl {
    final override = kIsWeb ? Uri.base.queryParameters['api'] : null;
    final uri = override == null ? null : Uri.tryParse(override);
    if (uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        uri.query.isEmpty &&
        uri.fragment.isEmpty &&
        (uri.path.isEmpty || uri.path == '/')) return uri.origin;
    return const String.fromEnvironment('API_URL',
        defaultValue: 'http://localhost:3001');
  }

  String baseUrl;
  String? token;

  /// A client can be injected by tests so no real network is required.
  Api({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? defaultUrl,
        client = client ?? http.Client();
  final http.Client client;

  /// GET when [body] is absent and POST JSON otherwise. The API always responds
  /// with JSON, including errors, so callers receive one predictable shape.
  Future<dynamic> request(String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$baseUrl/api$path');
    final response = await (body == null
            ? client.get(uri,
                headers: {if (token != null) 'Authorization': 'Bearer $token'})
            : client.post(uri,
                headers: {
                  'Content-Type': 'application/json',
                  if (token != null) 'Authorization': 'Bearer $token'
                },
                body: jsonEncode(body)))
        .timeout(const Duration(seconds: 5));
    dynamic data;
    try {
      data = response.body.isEmpty ? null : jsonDecode(response.body);
    } catch (_) {
      throw ApiException(response.statusCode,
          'The address did not return an API response. Check the host and port.');
    }
    if (response.statusCode >= 400) {
      throw ApiException(
          response.statusCode,
          data is Map
              ? data['error']?.toString() ??
                  'Request failed: ${response.statusCode}'
              : 'Request failed: ${response.statusCode}');
    }
    return data;
  }

  Future<void> login(String username, String password) async {
    final result = await request(
        '/auth/login', {'username': username, 'password': password});
    token = result['token'] as String;
  }

  Future<void> logout() async {
    try {
      await request('/auth/logout', {});
    } finally {
      token = null;
    }
  }

  /// Reuse the manual test device; create a fresh session only on user request.
  Future<String> createSession(String name, {String? deviceIp}) async {
    final devices = await request('/devices') as List;
    final serial = deviceIp == null ? 'MANUAL-001' : 'ESP32-UDP-$deviceIp';
    final deviceName =
        deviceIp == null ? 'Manual test input' : 'ESP32 UDP sender $deviceIp';
    final matching = devices.where((d) => d['serialNumber'] == serial);
    if (deviceIp != null && matching.isEmpty) {
      throw StateError('Pair the ESP32 sender before creating a session.');
    }
    final device = matching.isEmpty
        ? await request(
            '/devices', {'deviceName': deviceName, 'serialNumber': serial})
        : matching.first;
    // The API accepts at most millisecond precision, but Dart's
    // toIso8601String includes microseconds. Truncate before formatting.
    final now = DateTime.now().toUtc();
    final startTime = DateTime.fromMillisecondsSinceEpoch(
            now.millisecondsSinceEpoch,
            isUtc: true)
        .toIso8601String();
    final session = await request('/sessions', {
      'deviceId': device['deviceId'],
      'sessionName': name,
      'startTime': startTime,
      'notes': deviceIp == null
          ? 'Manually entered values; not hardware measurements.'
          : 'ESP32 UDP source $deviceIp; receiver timestamps from the buffered stream.',
    });
    return session['sessionId'] as String;
  }

  Future<List<dynamic>> deviceSources() async =>
      await request('/device-sources') as List<dynamic>;

  Future<String> createDirectSession(
      String name, String serial, String label) async {
    final devices = await request('/devices') as List;
    final matching = devices.where((d) => d['serialNumber'] == serial);
    final device = matching.isEmpty
        ? await request(
            '/devices', {'deviceName': label, 'serialNumber': serial})
        : matching.first;
    final session = await request('/sessions', {
      'deviceId': device['deviceId'],
      'sessionName': name,
      'startTime': DateTime.fromMillisecondsSinceEpoch(
              DateTime.now().millisecondsSinceEpoch,
              isUtc: true)
          .toIso8601String(),
      'notes':
          'Direct Android $label. Phone receive timestamps; not a synchronized device clock.',
    });
    return session['sessionId'] as String;
  }

  /// Fetch buffered device frames newer than [afterCursor]. Omitting the
  /// sequence returns only the cursor, so a new capture starts at the next
  /// frame instead of replaying buffered history into the session.
  Future<Map<String, dynamic>> deviceFrames(
      {String? sourceIp,
      int? afterCursor,
      String? streamId,
      int limit = 1000}) async {
    final params = <String, String>{
      if (sourceIp != null) 'sourceIp': sourceIp,
      'cursorMode': 'arrival',
      if (afterCursor != null) 'afterCursor': '$afterCursor',
      if (streamId != null) 'streamId': streamId,
      'limit': '$limit',
    };
    return Map<String, dynamic>.from(
        await request('/device-frames?${Uri(queryParameters: params).query}'));
  }

  Future<String> pairDevice(String sourceIp) async {
    final device =
        await request('/device-sources/pair', {'sourceIp': sourceIp});
    return device['deviceId'] as String;
  }

  /// Upload the exact timestamps and values saved by CaptureLog. Generating new
  /// timestamps during retry would defeat the database's idempotent key. The
  /// API accepts up to 1000 samples per request, so one call carries a batch.
  Future<void> uploadFrames(
      String sessionId, List<Map<String, dynamic>> frames) async {
    await request('/sessions/$sessionId/measurements', {
      'samples': [
        for (final frame in frames)
          {'recordedAt': frame['recordedAt'], 'channels': frame['channels']}
      ],
    });
  }

  Future<void> uploadFrame(String sessionId, Map<String, dynamic> frame) =>
      uploadFrames(sessionId, [frame]);

  /// Release keep-alive sockets when the owning Dashboard is disposed.
  void close() => client.close();
}
