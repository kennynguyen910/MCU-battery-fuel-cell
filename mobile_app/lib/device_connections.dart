import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:usb_serial/usb_serial.dart';
import 'api.dart';
import 'capture_log.dart';
import 'demo_widgets.dart';
import 'device_packets.dart';
import 'direct_capture.dart';
import 'wifi_settings.dart';
import 'wifi_transport.dart';
import 'wifi_protocol.dart';
import 'udp_receiver.dart';

const _platform = MethodChannel('capstone/connectivity');
final _service = Uuid.parse('5ecf0000-41c2-4cc4-9c96-640f406021d0');
final _voltage = Uuid.parse('5ecf0001-41c2-4cc4-9c96-640f406021d0');

/// Android direct transports. The parent collector pauses while this route owns
/// the durable log. Wi-Fi collection is native UDP and stays on this route.
class DeviceConnections extends StatefulWidget {
  final Api api;
  final CaptureLog? log;
  final String initialMode;
  const DeviceConnections(
      {super.key, required this.api, this.log, this.initialMode = 'BLE'});
  @override
  State<DeviceConnections> createState() => _DeviceConnectionsState();
}

class _DeviceConnectionsState extends State<DeviceConnections> {
  late final _ble = FlutterReactiveBle();
  late final _log = widget.log ?? CaptureLog();
  late final DirectCapture _capture = DirectCapture(widget.api, _log);
  final _name = TextEditingController(text: 'ESP32 direct capture');
  final _devices = <String, DiscoveredDevice>{};
  List<UsbDevice> _usbDevices = [];
  StreamSubscription<DiscoveredDevice>? _scan;
  StreamSubscription<ConnectionStateUpdate>? _connection;
  StreamSubscription<List<int>>? _values;
  StreamSubscription<UsbEvent>? _usbEvents;
  UsbPort? _port;
  UsbMeasurementLines _usbParser = UsbMeasurementLines();
  Timer? _timer, _scanTimer;
  late String _mode = widget.initialMode;
  String _status = 'Choose a connection.', _network = 'Checking…';
  String? _serial, _session, _usbDeviceName, _bleDeviceId;
  bool _ready = false, _working = false, _linked = false, _scanning = false;
  bool _leaving = false, _allowPop = false;
  int _generation = 0;
  late final _udp = NativeUdpReceiver(onSample: (frames, ip) {
    if (_mode != 'Wi-Fi') return;
    if (_serial == null) {
      _serial = 'ESP32-UDP-$ip';
      debugPrint('[collector] first UDP measurements sender=$ip');
    }
    _capture.addBatch(frames);
  }, onError: (error) {
    _capture.stop();
    _show('UDP receiver error: $error');
  });
  final _udpPort = TextEditingController(text: '5005');
  WifiStatus? _wifiStatus;
  bool _apiReachable = false, _uploadActive = false, _credentialsSent = false;
  String _apiStorage = 'unknown';
  DateTime? _lastApiCheck;

  Future<void> _startUdp() async {
    final port = int.tryParse(_udpPort.text);
    if (port == null || port < 1 || port > 65535)
      throw StateError('Enter a valid UDP port.');
    await _udp.start(port: port);
    if (!mounted || _leaving || !_udp.active) return;
    _linked = true;
    debugPrint('[collector] UDP receiver active port=${_udp.port}');
    _show('UDP receiver active on port ${_udp.port}. Keep this screen open.');
  }

  void _credentialsAcknowledged() {
    if (!_credentialsSent)
      debugPrint('[collector] Wi-Fi credentials acknowledged');
    _credentialsSent = true;
  }

  void _acceptWifiStatus(WifiStatus status) {
    if (_wifiStatus?.state != status.state) {
      debugPrint('[collector] ESP32 Wi-Fi state=${status.label}');
    }
    _wifiStatus = status;
    if (_mode == 'Wi-Fi' &&
        status.state == 2 &&
        status.ip != '0.0.0.0' &&
        _udp.sourceIp != status.ip) {
      // DHCP/network changes must not keep filtering for the old ESP32 address,
      // or silently mix a new source into the previous capture session.
      _capture.stop();
      _capture.clearLive();
      _serial = null;
      _session = null;
      _udp.sourceIp = status.ip;
      debugPrint(
          '[collector] UDP sender selected=${status.ip}; create a new session');
    }
  }

  Future<void> _checkApi() async {
    try {
      final response = await widget.api.client
          .get(Uri.parse('${widget.api.baseUrl}/health'))
          .timeout(const Duration(seconds: 3));
      final health = jsonDecode(response.body) as Map;
      final reachable =
          response.statusCode == 200 && health['service'] == 'capstone';
      if (_apiReachable != reachable)
        debugPrint('[collector] API reachable=$reachable');
      _apiReachable = reachable;
      _apiStorage = health['storage']?.toString() ?? 'unavailable';
    } catch (_) {
      if (_apiReachable) debugPrint('[collector] API unreachable');
      _apiReachable = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _initialize();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  Future<void> _initialize() async {
    try {
      await _log.load();
      _network = await _platform.invokeMethod<String>('network') ?? 'Unknown';
      if (mounted) setState(() => _ready = true);
      if (_mode == 'Wi-Fi') await _startUdp();
      _usbEvents = UsbSerial.usbEventStream?.listen((event) {
        if (event.event == UsbEvent.ACTION_USB_DETACHED &&
            event.device?.deviceName == _usbDeviceName) {
          _disconnect()
              .then((_) => _show('USB cable disconnected. Capture stopped.'));
        }
      });
    } catch (error) {
      _show('Cannot initialize connections: $error');
    }
  }

  void _show(String message) {
    if (mounted) setState(() => _status = message);
  }

  Future<void> _tick() async {
    if (!_ready || _leaving) return;
    if (_lastApiCheck == null ||
        DateTime.now().difference(_lastApiCheck!).inSeconds >= 3) {
      _lastApiCheck = DateTime.now();
      unawaited(_checkApi());
    }
    try {
      await _capture.drain(upload: false);
      if (_leaving) return;
      final uploading = _log.visiblePending(widget.api) > 0;
      if (uploading != _uploadActive)
        debugPrint('[collector] database upload active=$uploading');
      _uploadActive = uploading;
      unawaited(_capture.uploadPending().catchError((Object error) {
        if (error is ApiException &&
            (error.statusCode == 401 ||
                (error.statusCode == 404 &&
                    error.message == 'Session not found'))) {
          _capture.stop();
        }
        _show('Saved uploads pending: $error');
      }));
    } catch (error) {
      if (error is ApiException && error.statusCode == 401) {
        _capture.stop();
        _show(
            'Login expired. Return to the collector and sign in. Saved frames remain pending.');
      } else {
        _show('Saved uploads pending: $error');
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_working || _leaving) return;
    setState(() => _working = true);
    try {
      await operation();
    } catch (error) {
      _show('$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _stopScan() async {
    _scanTimer?.cancel();
    await _scan?.cancel();
    _scan = null;
    _scanning = false;
  }

  Future<void> _scanBle() async {
    await _disconnect();
    if (_mode == 'Wi-Fi') await _startUdp();
    final sdk = await _platform.invokeMethod<int>('sdk') ?? 31;
    final permissions = sdk >= 31
        ? [Permission.bluetoothScan, Permission.bluetoothConnect]
        : [Permission.locationWhenInUse];
    final granted = await permissions.request();
    if (granted.values.any((value) => !value.isGranted)) {
      throw StateError(
          'Bluetooth permission denied. Enable it in Android app settings and retry.');
    }
    await _ble.statusStream
        .firstWhere((s) => s != BleStatus.unknown)
        .timeout(const Duration(seconds: 5));
    if (_ble.status != BleStatus.ready) {
      throw StateError(
          'Bluetooth is ${_ble.status.name}. Turn on Bluetooth (and Location on older Android), then retry.');
    }
    _devices.clear();
    _scanning = true;
    _show('Searching for BatteryMonitor…');
    _scan = _ble.scanForDevices(
        withServices: [_service],
        scanMode: ScanMode.lowLatency).listen((device) {
      if (mounted) setState(() => _devices[device.id] = device);
    }, onError: (Object error) {
      _stopScan();
      _show('Scan failed: $error');
    });
    _scanTimer = Timer(const Duration(seconds: 10), () async {
      await _stopScan();
      _show(_devices.isEmpty
          ? 'No BatteryMonitor found. Check board power and BLE firmware.'
          : 'Select your ESP32 below.');
    });
  }

  Future<void> _connectBle(DiscoveredDevice device) async {
    await _disconnect();
    if (_mode == 'Wi-Fi') await _startUdp();
    final generation = _generation;
    final connected = Completer<void>();
    _show('Connecting to ${device.name.isEmpty ? device.id : device.name}…');
    _connection = _ble
        .connectToDevice(
            id: device.id, connectionTimeout: const Duration(seconds: 12))
        .listen((update) {
      if (generation != _generation) return;
      if (update.connectionState == DeviceConnectionState.connected &&
          !connected.isCompleted) {
        connected.complete();
      } else if (update.connectionState == DeviceConnectionState.disconnected) {
        if (!connected.isCompleted)
          connected.completeError(StateError('ESP32 disconnected.'));
        _bleDeviceId = null;
        if (_mode != 'Wi-Fi') {
          _linked = false;
          _capture.stop();
          _capture.clearLive();
        }
        debugPrint('[collector] BLE disconnected');
        _show('BLE disconnected. UDP reception is independent of BLE.');
      }
    }, onError: (Object error) {
      if (!connected.isCompleted) connected.completeError(error);
      _bleDeviceId = null;
      if (_mode != 'Wi-Fi') {
        _linked = false;
        _capture.stop();
        _capture.clearLive();
      }
      _show('BLE connection failed: $error');
    });
    try {
      await connected.future.timeout(const Duration(seconds: 15));
      final mtu = await _ble
          .requestMtu(deviceId: device.id, mtu: 128)
          .timeout(const Duration(seconds: 8));
      if (generation != _generation) return;
      _bleDeviceId = device.id;
      if (_mode != 'Wi-Fi') _serial = 'ESP32-BLE-${device.id}';
      debugPrint('[collector] BLE connected');
      _linked = true;
      if (mtu >= 83 && _mode != 'Wi-Fi')
        _values = _ble
            .subscribeToCharacteristic(QualifiedCharacteristic(
                deviceId: device.id,
                serviceId: _service,
                characteristicId: _voltage))
            .listen((bytes) {
          if (generation != _generation) return;
          try {
            _capture.add(decodeBleVoltage(bytes));
          } on FormatException {
            _capture.invalid++;
          }
        }, onError: (Object error) {
          _capture.stop();
          _capture.clearLive();
          _linked = false;
          _show('BLE notifications failed: $error. Reconnect to retry.');
        });
      _show(_mode == 'Wi-Fi'
          ? 'BLE connected. UDP receiver remains independent.'
          : mtu >= 83
              ? 'BLE connected · MTU $mtu · waiting for voltage notifications.'
              : 'BLE connected · Wi-Fi setup available. Voltage notifications need MTU 83 or higher.');
      if (mounted) {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => DeviceWifiSettings(
                    transport: BleProvisioningTransport(_ble, device.id),
                    configureCollector: true,
                    collectorPort: _udp.active ? _udp.port : 5005,
                    onStatus: _acceptWifiStatus,
                    onCredentialsAcknowledged: _credentialsAcknowledged)));
      }
    } catch (_) {
      await _disconnect();
      rethrow;
    }
  }

  Future<void> _findUsb() async {
    _usbDevices = await UsbSerial.listDevices();
    _show(_usbDevices.isEmpty
        ? 'No USB device found. Use a data cable and USB OTG adapter.'
        : 'Choose the connected ESP32.');
  }

  Future<void> _connectUsb(UsbDevice device) async {
    await _disconnect();
    final port = await device.create();
    if (port == null) throw StateError('Unsupported USB serial adapter.');
    _port = port;
    try {
      if (!await port.open())
        throw StateError('USB permission denied or port unavailable.');
      await port.setPortParameters(
          115200, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
      // Avoid asserting the ESP32 auto-program/reset control lines.
      await port.setDTR(false);
      await port.setRTS(false);
      _usbParser = UsbMeasurementLines();
      _usbDeviceName = device.deviceName;
      _serial =
          'ESP32-USB-${device.vid}-${device.pid}-${device.serial ?? device.deviceId}'
              .substring(
                  0,
                  ('ESP32-USB-${device.vid}-${device.pid}-${device.serial ?? device.deviceId}')
                      .length
                      .clamp(0, 100));
      _linked = true;
      final stream = port.inputStream;
      if (stream == null) throw StateError('USB serial input unavailable.');
      _values = stream.listen((bytes) {
        for (final sample in _usbParser.add(bytes)) {
          _capture.add(sample);
        }
      }, onError: (Object error) {
        _capture.stop();
        _linked = false;
        _capture.clearLive();
        _show('USB read failed: $error');
      }, onDone: () {
        _capture.stop();
        _linked = false;
        _capture.clearLive();
        _show('USB stream closed. Reconnect to retry.');
      });
      _show('USB connected at 115200 baud. Waiting for measurements.');
    } catch (_) {
      await _disconnect();
      rethrow;
    }
  }

  Future<void> _disconnect() async {
    _generation++;
    _credentialsSent = false;
    _capture.stop();
    await _udp.close();
    await _capture.drain(upload: false);
    _capture.clearLive();
    _linked = false;
    await _stopScan();
    await _values?.cancel();
    _values = null;
    await _connection?.cancel();
    _connection = null;
    await _port?.close();
    _port = null;
    _usbDeviceName = null;
    _bleDeviceId = null;
    _serial = null;
    _session = null;
  }

  Future<void> _createSession() async {
    if (_name.text.trim().isEmpty || _serial == null)
      throw StateError('Enter a session name and connect a device.');
    await _capture.drain();
    if (_capture.queued != 0)
      throw StateError('Wait for queued frames to be saved.');
    _session = await widget.api
        .createDirectSession(_name.text.trim(), _serial!, 'ESP32 $_mode');
    _show(
        'Session created. Press Start capture to save incoming measurements.');
  }

  Future<void> _leave([bool wifi = false]) async {
    if (_leaving || _working) return;
    _leaving = true;
    try {
      await _disconnect();
      await _capture.drain(upload: false);
      while (_capture.queued > 0) {
        await _capture.drain(upload: false);
      }
      // The parent owns a new log instance. Finish any acknowledgement commit
      // before handing the same journal back to it; outages leave durable data.
      try {
        await _capture.uploadsIdle;
      } catch (_) {/* Retry on the parent. */}
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.pop(context, wifi);
    } catch (error) {
      _show('Cannot leave until received frames are saved: $error');
    } finally {
      _leaving = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scanTimer?.cancel();
    _scan?.cancel();
    _values?.cancel();
    _connection?.cancel();
    _usbEvents?.cancel();
    _port?.close();
    unawaited(_udp.close());
    _udpPort.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fresh = !_capture.stale;
    final idle = _ready && !_working && !_leaving && !_capture.capturing;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Device connections')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'BLE',
                    label: Text('BLE'),
                    icon: Icon(Icons.bluetooth)),
                ButtonSegment(
                    value: 'Wi-Fi',
                    label: Text('Wi-Fi'),
                    icon: Icon(Icons.wifi)),
                ButtonSegment(
                    value: 'USB', label: Text('USB'), icon: Icon(Icons.usb)),
              ],
              selected: {
                _mode
              },
              onSelectionChanged: idle
                  ? (value) => _run(() async {
                        await _disconnect();
                        setState(() => _mode = value.first);
                        if (_mode == 'Wi-Fi')
                          await _startUdp();
                        else
                          _show('Choose a connection.');
                      })
                  : null),
          const SizedBox(height: 18),
          if (_mode == 'Wi-Fi')
            DemoSection(
                title: 'Direct Wi-Fi / UDP collector',
                subtitle: 'Phone network: $_network',
                children: [
                  const Text(
                      'ESP32 sends measurements directly to this phone. Keep this screen open while capturing. Connect phone and ESP32 to the same LAN; router client isolation must be off.'),
                  TextField(
                      controller: _udpPort,
                      enabled: idle && !_udp.active,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Collector UDP port')),
                  Text(
                      'UDP receiver: ${_udp.active ? "active on ${_udp.port}" : "inactive"}'),
                  Text(
                      'ESP32 sender: ${_udp.sourceIp ?? "waiting for a valid packet"}'),
                  Text(
                      'Datagrams: ${_udp.datagrams} | Invalid frames/datagrams: ${_udp.invalid} | Other senders ignored: ${_udp.ignored}'),
                  Text(
                      'ESP32 Wi-Fi: ${_wifiStatus?.label ?? "unknown (open BLE setup to check)"}'),
                  TextButton(
                      onPressed: idle
                          ? () => _run(() async {
                                await _platform
                                    .invokeMethod<void>('wifiSettings');
                              })
                          : null,
                      child: const Text('Open phone Wi-Fi settings')),
                  TextButton(
                      onPressed:
                          idle && !_udp.active ? () => _run(_startUdp) : null,
                      child: const Text('Start UDP receiver')),
                  TextButton(
                      onPressed: idle ? () => _run(_scanBle) : null,
                      child: const Text('Scan BLE for Wi-Fi setup')),
                  for (final device in _devices.values)
                    ListTile(
                        title:
                            Text(device.name.isEmpty ? device.id : device.name),
                        trailing: TextButton(
                            onPressed: idle
                                ? () => _run(() => _connectBle(device))
                                : null,
                            child:
                                const Text('Connect BLE / configure Wi-Fi'))),
                ]),
          if (_mode == 'BLE')
            DemoSection(
                title: 'ESP32 Bluetooth',
                subtitle:
                    'BatteryMonitor · 16 channels · approximately 10 updates/s',
                children: [
                  const Text(
                      'Turn on Bluetooth. Allow Nearby devices when Android asks. Keep this page open while capturing.'),
                  TextButton(
                      onPressed: idle ? () => _run(_scanBle) : null,
                      child:
                          Text(_scanning ? 'Restart scan' : 'Scan for ESP32')),
                  for (final device in _devices.values)
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(device.name.isEmpty
                            ? 'BatteryMonitor'
                            : device.name),
                        subtitle: Text('${device.id} · ${device.rssi} dBm'),
                        trailing: TextButton(
                            onPressed: idle
                                ? () => _run(() => _connectBle(device))
                                : null,
                            child: const Text('Connect'))),
                ]),
          if (_mode == 'USB')
            DemoSection(
                title: 'ESP32 over USB cable',
                subtitle: 'USB serial · 115200 baud',
                children: [
                  const Text(
                      'Connect the ESP32 with a USB data cable and OTG adapter. Accept Android’s USB access prompt. The current repository firmware sends diagnostic text only; install the supplied USB measurement extension to capture voltages.'),
                  TextButton(
                      onPressed: idle ? () => _run(_findUsb) : null,
                      child: const Text('Find USB devices')),
                  for (final device in _usbDevices)
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(device.productName ?? 'USB serial device'),
                        subtitle: Text(device.deviceName),
                        trailing: TextButton(
                            onPressed: idle
                                ? () => _run(() => _connectUsb(device))
                                : null,
                            child: const Text('Connect'))),
                  if (_usbParser.lastDiagnostic.isNotEmpty)
                    SelectableText(
                        'Board console: ${_usbParser.lastDiagnostic}'),
                ]),
          Text(_status),
          Text('BLE: ${_bleDeviceId == null ? "disconnected" : "connected"}'),
          Text(
              'Wi-Fi credentials: ${_credentialsSent ? "sent and acknowledged" : "not acknowledged in this connection"}'),
          Text(
              'API: ${_apiReachable ? "reachable" : "unreachable"} | Storage: $_apiStorage'),
          Text(
              'Database upload: ${_uploadActive ? "active / retrying saved frames" : "idle"}'),
          if (_linked && _bleDeviceId != null)
            TextButton(
                onPressed: !_working
                    ? () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => DeviceWifiSettings(
                                transport: BleProvisioningTransport(
                                    _ble, _bleDeviceId!),
                                configureCollector: true,
                                collectorPort: _udp.active ? _udp.port : 5005,
                                onStatus: _acceptWifiStatus,
                                onCredentialsAcknowledged:
                                    _credentialsAcknowledged)))
                    : null,
                child: const Text('Settings · Wi-Fi')),
          ...[
            const SizedBox(height: 14),
            MeasurementSourceBadge(
                _capture.latest?.sourceLabel ?? 'UNKNOWN SOURCE / NO DATA'),
            Text(_linked
                ? (fresh ? 'Receiving measurements' : 'STALE / NO LIVE DATA')
                : 'Disconnected'),
            Text(
                'Received: ${_capture.received} · Invalid: ${_capture.invalid + _usbParser.invalid} · Duplicates: ${_capture.duplicates}'),
            Text(
                'Uploaded: ${_capture.uploaded} · Saved pending: ${_log.visiblePending(widget.api)} · Waiting to save: ${_capture.queued}'),
            Text(
                'Transport: $_mode · Sequence: ${_capture.integrity.lastSequence ?? '-'} · Missing sequence slots: ${_capture.integrity.missing} · Out of order: ${_capture.integrity.outOfOrder} · Restarts (estimated): ${_capture.integrity.restarts} · Invalid timestamps: ${_capture.integrity.invalidTimestamps}'),
            Text(
                'Frame age: ${_capture.receivedAt == null ? '-' : DateTime.now().difference(_capture.receivedAt!).inMilliseconds} ms · BLE has no application CRC; USB invalid frames: ${_usbParser.invalid}'),
            if (_mode == 'BLE')
              const Text(
                  'BLE receives latest frames at 10 Hz. Skipped acquisition sequence slots include intentional downsampling.'),
            if (_capture.overflow > 0)
              const Text(
                  'Capture stopped: receive buffer full. Restore uploads before restarting.'),
            TextField(
                controller: _name,
                enabled: idle,
                decoration: const InputDecoration(labelText: 'Session name')),
            Wrap(spacing: 8, children: [
              TextButton(
                  onPressed: idle && _linked && _serial != null
                      ? () => _run(_createSession)
                      : null,
                  child: const Text('Create session')),
              FilledButton(
                  onPressed: _ready &&
                          !_working &&
                          (_capture.capturing ||
                              (_linked && fresh && _session != null))
                      ? () => _run(() async {
                            if (_capture.capturing) {
                              _capture.stop();
                              await _capture.drain();
                            } else {
                              _capture.start(_session!);
                            }
                          })
                      : null,
                  child: Text(
                      _capture.capturing ? 'Stop capture' : 'Start capture')),
              TextButton(
                  onPressed: !_working && _linked
                      ? () => _run(() async {
                            await _disconnect();
                            _show('Disconnected. Capture stopped.');
                          })
                      : null,
                  child: const Text('Disconnect')),
            ]),
            Text(_capture.capturing ? 'Capture running' : 'Capture stopped'),
            const SizedBox(height: 14),
            VoltageTiles(List<double?>.generate(
                16, (i) => fresh ? _capture.latest!.channels[i] : null)),
          ],
        ]),
      ),
    );
  }
}
