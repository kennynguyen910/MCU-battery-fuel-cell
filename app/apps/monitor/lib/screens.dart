// Shared bench and demo screens. Each role retains its own data responsibilities.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'api.dart';
import 'capture_log.dart';
import 'history.dart';
import 'demo_widgets.dart';
import 'device_connections.dart';

/// The role controls capabilities, not merely labels: input publishes transient
/// frames, mobile captures/uploads, and web reads stored history.
enum AppRole { mobile, input, web, network }

/// Role entry points share ordinary widgets and one HTTP contract.
/// The role is fixed by the entry point, not by a device/browser guess.
class CapstoneApp extends StatefulWidget {
  final AppRole role;
  const CapstoneApp({super.key, required this.role});
  @override
  State<CapstoneApp> createState() => _CapstoneAppState();
}

class _CapstoneAppState extends State<CapstoneApp> {
  final Api sharedApi = Api();
  @override
  void dispose() {
    sharedApi.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: widget.role == AppRole.web
            ? 'Capstone web history'
            : 'Capstone collector',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff087e8b)),
          scaffoldBackgroundColor: const Color(0xfff3f6fa),
          inputDecorationTheme: const InputDecorationTheme(
              border: OutlineInputBorder(),
              filled: true,
              fillColor: Colors.white),
        ),
        home: Dashboard(role: widget.role, api: sharedApi),
        routes: {
          '/mobile': (_) => Dashboard(role: AppRole.mobile, api: sharedApi),
          '/input': (_) => Dashboard(role: AppRole.input, api: sharedApi),
          '/network': (_) => Dashboard(role: AppRole.network, api: sharedApi),
        },
      );
}

class Dashboard extends StatefulWidget {
  // Optional dependencies make behavior testable with fake HTTP/storage.
  final AppRole role;
  final Api? api;
  final CaptureLog? log;
  const Dashboard({super.key, required this.role, this.api, this.log});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  // Network and durable-log services live for the lifetime of this screen.
  late final Api api;
  late final CaptureLog log;
  bool logReady = false;
  // Controllers preserve user input while one-second polling rebuilds widgets.
  final address = TextEditingController(text: Api.defaultUrl);
  final username = TextEditingController();
  final password = TextEditingController();
  final sessionName = TextEditingController(text: 'Manual bench test');
  final inputs = List.generate(16, (_) => TextEditingController(text: '0'));
  List<dynamic> sessions = [], rows = [];
  int storedMeasurementCount = 0;
  bool historyTruncated = false;
  List<double>? live;
  bool loginRequired = false, deviceMode = false;
  List<dynamic> deviceSources = [];
  String? deviceIp;
  String? pairedDeviceId;
  bool deviceStale = true;
  Map<String, dynamic> deviceMetrics = {}, simulation = {};
  final bool demoMode = kIsWeb && Uri.base.queryParameters['demo'] == '1';
  String captureSummary = '';
  int deviceFrames = 0;
  // `selected` is the active session UUID; `lastFrame` suppresses duplicates.
  // `lastDeviceCursor` is the buffered-stream cursor for UDP device capture.
  String? selected, lastFrame;
  int? lastDeviceCursor;
  String? deviceStreamId;
  int missedBufferedFrames = 0;
  String historyQuery = '';
  String status = 'Connecting...', notice = '';
  // `busy` protects polling, while `action` protects user-triggered operations.
  bool busy = false, action = false, capturing = false;
  int uploaded = 0;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    api = widget.api ?? Api();
    address.text = api.baseUrl;
    username.text = 'capstone';
    if (demoMode) {
      sessionName.text = 'Network demo';
    }
    log = widget.log ?? CaptureLog();
    initialize();
    // The API buffers the UDP stream, so this modest poll rate still collects
    // every frame by paging through the buffer instead of sampling the latest.
    timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
  }

  /// Load durable state before allowing polling, then perform the first refresh.
  Future<void> initialize() async {
    try {
      if (widget.role == AppRole.mobile) await log.load();
      if (!mounted) return;
      setState(() => logReady = true);
      await refresh();
    } catch (error) {
      if (mounted) setState(() => status = 'Cannot open local log: $error');
    }
  }

  /// Poll only the data needed by the current role. The guard prevents a slow
  /// request from overlapping the next timer tick or a button action.
  Future<void> refresh() async {
    if (busy || action || !logReady || loginRequired) return;
    busy = true;
    try {
      if (widget.role == AppRole.network) {
        simulation =
            Map<String, dynamic>.from(await api.request('/simulation'));
      } else if (widget.role == AppRole.input) {
        // A successful read proves the input dashboard can reach the API.
        await api.request('/test-input');
      } else {
        if (widget.role == AppRole.mobile && deviceMode) {
          deviceSources = await api.deviceSources();
          if (!deviceSources.any((s) => s['sourceIp'] == deviceIp)) {
            if (capturing) {
              capturing = false;
              notice =
                  'The selected sender disappeared. Select it again before starting capture.';
            }
            final paired = deviceSources.where((s) => s['deviceId'] != null);
            deviceIp = paired.isNotEmpty
                ? paired.first['sourceIp'] as String
                : (deviceSources.isEmpty
                    ? null
                    : deviceSources.first['sourceIp'] as String);
            lastDeviceCursor = null;
          }
          final selectedSource =
              deviceSources.where((s) => s['sourceIp'] == deviceIp);
          pairedDeviceId = selectedSource.isEmpty
              ? null
              : selectedSource.first['deviceId'] as String?;
          deviceStale =
              selectedSource.isEmpty || selectedSource.first['stale'] == true;
        }
        final allSessions = await api.request('/sessions') as List;
        final list = widget.role == AppRole.mobile
            ? allSessions
                .where((s) =>
                    s['serialNumber'] ==
                    (deviceMode ? 'ESP32-UDP-$deviceIp' : 'MANUAL-001'))
                .toList()
            : allSessions;
        if (!mounted) return;
        sessions = list;
        if (!list.any((s) => s['sessionId'] == selected)) {
          // Default to the newest session when the old selection disappears.
          selected = list.isEmpty ? null : list.first['sessionId'] as String;
          rows = [];
        }
        if (widget.role == AppRole.mobile) {
          // Clear a recovered upload backlog before accepting another page.
          // Otherwise a full local log could prevent its own retry indefinitely.
          uploaded += await log.flush(api);
          dynamic frame;
          bool invalidVoltage = false;
          if (deviceMode) {
            final query = deviceIp == null ? '' : '?sourceIp=$deviceIp';
            final device = await api.request('/device-input$query') as Map;
            deviceMetrics = Map<String, dynamic>.from(device);
            deviceFrames = device['receivedFrames'] as int? ?? 0;
            deviceStale = device['stale'] == true;
            frame = deviceStale ? null : device['frame'];
            if (deviceStale) live = null;
          } else {
            frame = await api.request('/test-input');
          }
          if (!mounted) return;
          if (frame != null) {
            // Displaying a frame does not mean it was captured or stored.
            live = (frame['channels'] as List)
                .map((v) => (v as num).toDouble())
                .toList();
            invalidVoltage = live!.length != 16 ||
                live!.any((v) => !v.isFinite || v < -5 || v > 5);
          }
          if (capturing && selected != null) {
            final sessionId = selected!;
            if (deviceMode) {
              // Page through the server-side buffer so every wire-rate frame is
              // logged, not just the one latest sample visible to this poll.
              if (deviceIp != null) {
                for (var fetch = 0; fetch < 3; fetch += 1) {
                  final result = await api.deviceFrames(
                      sourceIp: deviceIp,
                      afterCursor: lastDeviceCursor,
                      streamId: deviceStreamId);
                  if (!mounted || !capturing || selected != sessionId) return;
                  if (result['streamReset'] == true) {
                    capturing = false;
                    notice =
                        'Receiver restarted. Start capture again to use the new stream.';
                    break;
                  }
                  final frames = (result['frames'] as List)
                      .whereType<Map>()
                      .map((f) => Map<String, dynamic>.from(f))
                      .where((f) {
                    final channels = f['channels'];
                    return channels is List &&
                        channels.length == 16 &&
                        channels.every(
                            (v) => v is num && v.isFinite && v >= -5 && v <= 5);
                  }).toList();
                  await log.appendAll(api.baseUrl, sessionId, frames);
                  // Advance only after the fetched page has been saved locally.
                  lastDeviceCursor =
                      result['nextCursor'] as int? ?? lastDeviceCursor;
                  deviceStreamId = result['streamId'] as String?;
                  missedBufferedFrames += result['missedFrames'] as int? ?? 0;
                  if (result['hasMore'] != true) break;
                }
              }
            } else if (frame != null &&
                !invalidVoltage &&
                frame['frameId'] != lastFrame) {
              // Only a new frame is uploaded. Re-reading the same device value
              // must not generate a new timestamp or duplicate measurements.
              await log.append(
                  api.baseUrl, sessionId, Map<String, dynamic>.from(frame));
              if (!mounted) return;
              lastFrame = frame['frameId'] as String;
            }
          }
          // Retry saved uploads even when capture has since been stopped. Stop
          // affects accepting new frames, never the safety of already-saved work.
          uploaded += await log.flush(api);
          captureSummary = invalidVoltage
              ? 'Device frame outside ±5 V or incomplete; shown but not uploaded.'
              : 'Uploaded $uploaded frame(s) in this app run. Pending: ${log.pending}. Buffer losses: $missedBufferedFrames.';
        } else if (selected != null) {
          // Remember both values so an older response cannot overwrite a newer
          // session selection or time-filter request.
          final id = selected!;
          final query = historyQuery;
          final data = await api.request(
              '/sessions/$id$query${query.isEmpty ? '?' : '&'}recent=1');
          if (!mounted) return;
          if (id == selected && query == historyQuery) {
            rows = data['measurements'] as List;
            storedMeasurementCount =
                data['measurementCount'] as int? ?? rows.length;
            historyTruncated = data['truncated'] == true;
          }
        }
      }
      if (mounted) setState(() => status = 'Connected');
    } catch (error) {
      if (mounted)
        setState(() {
          if (error is ApiException && error.statusCode == 401) {
            loginRequired = true;
            capturing = false;
            api.token = null;
            live = null;
            rows = [];
            notice = 'Please log in to continue. Capture is stopped.';
          }
          status = 'Disconnected / stale: $error';
        });
    } finally {
      busy = false;
    }
  }

  Future<void> setScenario(String scenario) async {
    if (busy || action) return;
    setState(() => action = true);
    try {
      final result = await api.request('/simulation', {'scenario': scenario});
      if (mounted)
        setState(() {
          simulation = Map<String, dynamic>.from(result);
          notice = '';
        });
    } catch (error) {
      if (mounted) setState(() => notice = 'Could not change scenario: $error');
    } finally {
      if (mounted) setState(() => action = false);
    }
  }

  /// Create a named test session attached to the reusable manual device.
  Future<void> createSession() async {
    if (sessionName.text.trim().isEmpty) return;
    setState(() => action = true);
    try {
      if (deviceMode && deviceIp == null) {
        throw Exception(
            'No ESP32 UDP frames received yet. Check router and device IP.');
      }
      if (deviceMode && pairedDeviceId == null) {
        throw StateError('Pair the selected ESP32 sender first.');
      }
      final id = await api.createSession(sessionName.text.trim(),
          deviceIp: deviceMode ? deviceIp : null);
      final allSessions = await api.request('/sessions') as List;
      final list = allSessions
          .where((s) =>
              s['serialNumber'] ==
              (deviceMode ? 'ESP32-UDP-$deviceIp' : 'MANUAL-001'))
          .toList();
      if (!mounted) return;
      setState(() {
        selected = id;
        sessions = list;
        lastFrame = null;
        notice =
            'Session created. Press Start capture, then send device input.';
      });
    } catch (error) {
      if (mounted) setState(() => notice = 'Create failed: $error');
    } finally {
      if (mounted) setState(() => action = false);
    }
  }

  Future<void> pairSelectedDevice() async {
    if (deviceIp == null) return;
    setState(() => action = true);
    try {
      final id = await api.pairDevice(deviceIp!);
      if (mounted)
        setState(() {
          pairedDeviceId = id;
          notice =
              'Paired ESP32 sender $deviceIp. Create a session to capture.';
        });
    } catch (error) {
      if (mounted) setState(() => notice = 'Pairing failed: $error');
    } finally {
      if (mounted) setState(() => action = false);
    }
    if (mounted) await refresh();
  }

  /// Stopping is local and immediate. Starting records a baseline so a frame
  /// published before the button click cannot leak into the new capture.
  Future<void> toggleCapture() async {
    if (capturing) {
      setState(() {
        capturing = false;
        notice = 'Capture stopped. Already logged uploads can finish.';
      });
      return;
    }
    setState(() => action = true);
    try {
      // Start from the next published frame, never a stale pre-session value.
      dynamic baseline;
      if (deviceMode) {
        final source = await api.request('/device-input?sourceIp=$deviceIp');
        if (source['stale'] == true || pairedDeviceId == null)
          throw StateError(
              'Select a paired, live sender before starting capture.');
        // Baseline cursor: frames already buffered stay out of this capture.
        final cursor = await api.deviceFrames(sourceIp: deviceIp);
        lastDeviceCursor = cursor['nextCursor'] as int?;
        deviceStreamId = cursor['streamId'] as String?;
        missedBufferedFrames = 0;
      } else {
        baseline = await api.request('/test-input');
      }
      if (!mounted) return;
      setState(() {
        lastFrame = baseline?['frameId'] as String?;
        capturing = true;
        notice = 'Capture started. New readings are logged before upload.';
      });
    } catch (error) {
      if (mounted) setState(() => notice = 'Cannot start capture: $error');
    } finally {
      if (mounted) setState(() => action = false);
    }
  }

  Future<void> signIn() async {
    setState(() => action = true);
    try {
      await api.login(username.text.trim(), password.text);
      password.clear();
      if (!mounted) return;
      setState(() {
        loginRequired = false;
        notice = '';
      });
    } catch (error) {
      if (mounted) setState(() => notice = 'Login failed: $error');
    } finally {
      if (mounted) setState(() => action = false);
    }
    if (mounted && !loginRequired) await refresh();
  }

  Future<void> signOut() async {
    setState(() => action = true);
    try {
      await api.logout();
    } catch (_) {
      api.token = null;
    }
    if (mounted)
      setState(() {
        action = false;
        loginRequired = true;
        capturing = false;
        sessions = [];
        rows = [];
        live = null;
        selected = null;
        notice = 'Logged out.';
      });
  }

  Future<void> openDeviceConnections() async {
    if (action || capturing) return;
    setState(() => action = true);
    try {
      // Let an existing upload finish; pause new polls while this route owns the log.
      while (busy && mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!mounted) return;
      final wifi = await Navigator.push<bool>(context,
          MaterialPageRoute(builder: (_) => DeviceConnections(api: api)));
      // The direct receiver owned this file while polling was paused.
      await log.load();
      if (mounted && wifi == true)
        setState(() {
          deviceMode = true;
          selected = null;
          lastDeviceCursor = null;
        });
    } finally {
      if (mounted) setState(() => action = false);
    }
    if (mounted) await refresh();
  }

  void connectToApi() {
    final uri = Uri.tryParse(address.text.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      setState(() => notice = 'Enter an http:// or https:// API address.');
      return;
    }
    setState(() {
      api.baseUrl = address.text.trim().replaceFirst(RegExp(r'/$'), '');
      api.token = null;
      selected = null;
      rows = [];
      sessions = [];
      capturing = false;
      lastFrame = null;
      lastDeviceCursor = null;
      loginRequired = false;
      deviceIp = null;
      pairedDeviceId = null;
      deviceSources = [];
      deviceMetrics = {};
      deviceStale = true;
      live = null;
      historyQuery = '';
      notice = '';
      captureSummary = '';
    });
    refresh();
  }

  /// Validate every input locally, then publish one complete transient frame.
  Future<void> publish() async {
    final values = inputs.map((c) => double.tryParse(c.text.trim())).toList();
    if (values.any((v) => v == null || !v.isFinite || v < -5 || v > 5)) {
      setState(
          () => notice = 'Enter all 16 numbers, each between -5 and +5 V.');
      return;
    }
    setState(() => action = true);
    try {
      await api.request('/test-input', {'channels': values.cast<double>()});
      if (mounted)
        setState(() =>
            notice = 'Frame published. A running mobile collector uploads it.');
    } catch (error) {
      if (mounted) setState(() => notice = 'Publish failed: $error');
    } finally {
      if (mounted) setState(() => action = false);
    }
  }

  @override
  void dispose() {
    // Timers, sockets, and controllers otherwise outlive a removed route in tests.
    timer?.cancel();
    if (widget.api == null) api.close();
    address.dispose();
    username.dispose();
    password.dispose();
    sessionName.dispose();
    for (final input in inputs) {
      input.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final role = widget.role;
    final sorted = [...rows]..sort((a, b) =>
        (a['recordedAt'] as String).compareTo(b['recordedAt'] as String));
    final latest = <int, dynamic>{};
    for (final row in sorted) {
      latest[row['channel'] as int] = row;
    }
    final title = switch (role) {
      AppRole.input => 'Manual device input',
      AppRole.mobile => 'Mobile collector',
      AppRole.web => 'Measurement history',
      AppRole.network => 'Network lab',
    };
    final ready = !busy && !action;
    Widget gap() => const SizedBox(height: 14);
    return Scaffold(
      appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(MediaQuery.sizeOf(context).width < 600
              ? title
              : 'CAPSTONE  /  $title'),
          backgroundColor: const Color(0xff102c3c),
          foregroundColor: Colors.white,
          actions: [
            if (api.token != null)
              TextButton(
                  onPressed: ready ? signOut : null,
                  child: const Text('Log out',
                      style: TextStyle(color: Colors.white))),
          ]),
      body: Center(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          if (!kIsWeb &&
              defaultTargetPlatform == TargetPlatform.android &&
              role == AppRole.mobile)
            Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: OutlinedButton.icon(
                    onPressed:
                        !action && !capturing ? openDeviceConnections : null,
                    icon: const Icon(Icons.settings_input_antenna),
                    label:
                        const Text('Device connections · BLE / Wi-Fi / USB'))),
          if (demoMode)
            Container(
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: const Color(0xffffedcb),
                    borderRadius: BorderRadius.circular(12)),
                child: const Text(
                    'DEMO • Synthetic readings • Temporary data resets when the demo server stops.')),
          if (kIsWeb)
            Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Wrap(spacing: 10, children: [
                  for (final page in const {
                    '/network': 'Network lab',
                    '/mobile': 'Collector',
                    '/': 'History'
                  }.entries)
                    OutlinedButton(
                        onPressed: capturing || !ready
                            ? null
                            : () => Navigator.pushReplacementNamed(
                                context, page.key),
                        child: Text(page.value)),
                ])),
          DemoSection(
              title: loginRequired ? 'Sign in to your workspace' : 'Connection',
              subtitle: loginRequired
                  ? 'Enter your Capstone account to connect to the device and saved sessions.'
                  : status,
              children: [
                TextField(
                    controller: address,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                        labelText: 'API address',
                        prefixIcon: Icon(Icons.link))),
                Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                        onPressed: ready ? connectToApi : null,
                        icon: const Icon(Icons.sync),
                        label: const Text('Connect'))),
                if (loginRequired) ...[
                  TextField(
                      controller: username,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person_outline))),
                  gap(),
                  TextField(
                      controller: password,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) {
                        if (ready) signIn();
                      },
                      decoration: const InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock_outline))),
                  gap(),
                  ElevatedButton(
                      onPressed: ready ? signIn : null,
                      child: Text(action ? 'Signing in…' : 'Log in')),
                ],
                if (notice.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(notice)),
              ]),
          if (!loginRequired) ...[
            if (role == AppRole.network)
              NetworkLabPanel(
                  data: simulation, busy: !ready, onScenario: setScenario),
            if (role == AppRole.mobile)
              DemoSection(
                  title: '1. Select and pair a device',
                  subtitle:
                      'Choose manual input or a sender connected to the laptop receiver.',
                  children: [
                    DropdownButton<bool>(
                        value: deviceMode,
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(
                              value: false, child: Text('Manual test input')),
                          DropdownMenuItem(
                              value: true,
                              child: Text('ESP32 over laptop Wi-Fi / UDP'))
                        ],
                        onChanged: capturing || !ready
                            ? null
                            : (value) {
                                setState(() {
                                  deviceMode = value ?? false;
                                  lastFrame = null;
                                  lastDeviceCursor = null;
                                  live = null;
                                  selected = null;
                                  pairedDeviceId = null;
                                });
                                refresh();
                              }),
                    if (deviceMode) ...[
                      if (deviceSources.isEmpty)
                        const Text(
                            'Waiting for a sender. Start a network scenario or check the device Wi-Fi and laptop destination address.'),
                      if (deviceSources.isNotEmpty)
                        DropdownButton<String>(
                            value: deviceIp,
                            isExpanded: true,
                            items: deviceSources
                                .map((s) => DropdownMenuItem<String>(
                                    value: s['sourceIp'] as String,
                                    child: Text(
                                        '${s['sourceIp'] == '127.0.0.1' ? 'Simulator' : s['sourceIp']} — ${s['stale'] == true ? 'offline' : 'online'} · ${s['deviceId'] == null ? 'unpaired' : 'paired'}',
                                        overflow: TextOverflow.ellipsis)))
                                .toList(),
                            onChanged: capturing || !ready
                                ? null
                                : (ip) {
                                    setState(() {
                                      deviceIp = ip;
                                      selected = null;
                                      live = null;
                                      lastFrame = null;
                                      pairedDeviceId = null;
                                    });
                                    refresh();
                                  }),
                      if (deviceIp != null) ...[
                        gap(),
                        StatTiles({
                          'Device connection': deviceStale ? 'Offline' : 'Live',
                          'Received frames': '$deviceFrames',
                          'Frames / second':
                              '${deviceMetrics['framesPerSecond'] ?? 0}',
                          'Estimated missing':
                              '${deviceMetrics['missingFrames'] ?? 0}',
                          'CRC errors': '${deviceMetrics['crcErrors'] ?? 0}',
                        }),
                        gap()
                      ],
                      if (deviceIp != null && pairedDeviceId == null)
                        ElevatedButton.icon(
                            onPressed: ready && !deviceStale
                                ? pairSelectedDevice
                                : null,
                            icon: const Icon(Icons.add_link),
                            label: const Text('Pair selected device')),
                      if (pairedDeviceId != null)
                        const Text(
                            'Paired • Sessions below belong to this sender.'),
                    ],
                  ]),
            if (role == AppRole.mobile || role == AppRole.web)
              DemoSection(
                  title: role == AppRole.mobile
                      ? '2. Choose a test session'
                      : 'Saved sessions',
                  children: [
                    if (sessions.isEmpty)
                      const Text(
                          'No sessions yet. Create one in the mobile collector.'),
                    if (sessions.isNotEmpty)
                      DropdownButton<String>(
                          isExpanded: true,
                          value: selected,
                          hint: const Text('Select test session'),
                          items: sessions
                              .map((s) => DropdownMenuItem<String>(
                                  value: s['sessionId'] as String,
                                  child: Text(
                                      '${s['sessionName']} — ${s['startTime']}',
                                      overflow: TextOverflow.ellipsis)))
                              .toList(),
                          onChanged: !ready || capturing
                              ? null
                              : (id) {
                                  setState(() {
                                    selected = id;
                                    rows = [];
                                    lastFrame = null;
                                  });
                                  refresh();
                                }),
                    if (role == AppRole.mobile) ...[
                      gap(),
                      TextField(
                          controller: sessionName,
                          decoration: const InputDecoration(
                              labelText: 'New session name')),
                      gap(),
                      ElevatedButton(
                          onPressed: !ready ||
                                  capturing ||
                                  (deviceMode && pairedDeviceId == null)
                              ? null
                              : createSession,
                          child: const Text('Create session')),
                    ],
                  ]),
            if (role == AppRole.mobile)
              DemoSection(
                  title: '3. Capture readings',
                  subtitle: deviceMode
                      ? 'Buffered capture saves received frames in batches. The screen refreshes once per second; buffer losses are reported below.'
                      : 'Publish a new manual frame after starting capture.',
                  children: [
                    ElevatedButton.icon(
                        onPressed: capturing
                            ? toggleCapture
                            : (selected == null ||
                                    !ready ||
                                    (deviceMode &&
                                        (deviceStale || pairedDeviceId == null))
                                ? null
                                : toggleCapture),
                        icon: Icon(capturing
                            ? Icons.stop_circle_outlined
                            : Icons.play_arrow),
                        label:
                            Text(capturing ? 'Stop capture' : 'Start capture')),
                    gap(),
                    Text(capturing
                        ? (deviceMode && deviceStale
                            ? 'Capture waiting — sender offline'
                            : 'Capture running')
                        : 'Capture stopped — values are not uploaded'),
                    if (captureSummary.isNotEmpty) Text(captureSummary),
                    gap(),
                    VoltageTiles(List.generate(
                        16,
                        (i) => live != null && i < live!.length
                            ? live![i]
                            : null)),
                    TextButton(
                        onPressed: !logReady
                            ? null
                            : () => showDialog<void>(
                                context: context,
                                builder: (context) =>
                                    AlertDialog(
                                        title: const Text('Local JSON log'),
                                        content: SizedBox(
                                            width: 620,
                                            child: SingleChildScrollView(
                                                child:
                                                    SelectableText(log.json))),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: const Text('Close'))
                                        ])),
                        child: Text(
                            'View local log (${log.entries.length} frames; ${log.pending} pending)')),
                  ]),
            if (role == AppRole.input)
              DemoSection(
                  title: 'Publish a manual frame',
                  subtitle:
                      'Enter all 16 voltages from −5 to +5 V. Start capture in the collector first.',
                  children: [
                    for (var i = 0; i < 16; i++)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TextField(
                              controller: inputs[i],
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true, signed: true),
                              decoration: InputDecoration(
                                  labelText: 'CH ${i + 1} (V)'))),
                    ElevatedButton(
                        onPressed: ready ? publish : null,
                        child: const Text('Publish device frame')),
                  ]),
            if (role == AppRole.web)
              DemoSection(
                  title: 'Voltage history',
                  subtitle:
                      'Review values saved by the collector in the selected session.',
                  children: [
                    HistoryPanel(
                        rows: rows,
                        onFilter: (from, to) {
                          final params = <String, String>{
                            if (from != null) 'from': from.toIso8601String(),
                            if (to != null) 'to': to.toIso8601String()
                          };
                          setState(() {
                            historyQuery = params.isEmpty
                                ? ''
                                : '?${Uri(queryParameters: params).query}';
                            rows = [];
                          });
                          refresh();
                        }),
                    gap(),
                    VoltageTiles(List.generate(16,
                        (i) => (latest[i]?['voltage'] as num?)?.toDouble())),
                    gap(),
                    Text(sorted.isEmpty
                        ? 'No stored samples.'
                        : 'Last saved (UTC): ${sorted.last['recordedAt']}'),
                    Text('Stored measurement rows: $storedMeasurementCount'),
                    if (historyTruncated)
                      const Text(
                          'Chart shows the latest 1,000 samples in this range. All samples remain saved; narrow the time range to review older data.'),
                  ]),
          ],
        ]),
      )),
    );
  }
}
