import 'dart:async';
import 'package:flutter/material.dart';
import 'wifi_transport.dart';
import 'wifi_protocol.dart';

class DeviceWifiSettings extends StatefulWidget {
  final ProvisioningTransport transport;
  const DeviceWifiSettings({super.key, required this.transport});
  @override
  State<DeviceWifiSettings> createState() => _DeviceWifiSettingsState();
}

class _DeviceWifiSettingsState extends State<DeviceWifiSettings> {
  final _subscriptions = <StreamSubscription<List<int>>>[];
  final _objects = ProvisioningObjects();
  final _networks = <String, WifiNetwork>{};
  final _ssid = TextEditingController(), _password = TextEditingController();
  WifiStatus? _status;
  String _message = 'Reading device Wi-Fi status…', _currentNetwork = '';
  bool _busy = false, _available = false;
  int _next = 0, _scanTransaction = 0, _credentialsTransaction = 0;
  bool _closed = false;
  Completer<void>? _ack;
  int _pendingTransaction = 0, _pendingOpcode = 0;
  Timer? _scanTimeout;

  void _update(void Function() change) {
    if (mounted) setState(change);
  }

  int _transaction() => _next = _next % 255 + 1;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await widget.transport.discover();
      if (_closed) return;
      for (final uuid in [
        provisioningControl,
        provisioningData,
        provisioningStatus
      ]) {
        _subscriptions.add(widget.transport.subscribe(uuid).listen((bytes) {
          try {
            if (uuid == provisioningStatus) {
              final status = WifiStatus.decode(bytes);
              _update(() {
                _status = status;
                if (status.state == 0) _currentNetwork = '';
                _message = status.state == 3
                    ? provisioningError(status.error == 0 ? 10 : status.error)
                    : status.error != 0
                        ? provisioningError(status.error)
                        : status.state == 0
                            ? 'Set up Wi-Fi? Scan nearby networks to begin.'
                            : status.label;
              });
            } else if (uuid == provisioningControl) {
              if (bytes.length < 4 ||
                  bytes[0] != 1 ||
                  bytes.length != 4 + bytes[3]) {
                throw const FormatException('Invalid control response');
              }
              if ([0x80, 0x81].contains(bytes[1])) {
                if (bytes.length != 6)
                  throw const FormatException('Invalid acknowledgment');
                if (bytes[2] == _pendingTransaction &&
                    bytes[4] == _pendingOpcode &&
                    _ack != null &&
                    !_ack!.isCompleted) {
                  if (bytes[1] == 0x81 || bytes[5] != 0) {
                    _ack!
                        .completeError(StateError(provisioningError(bytes[5])));
                  } else {
                    _ack!.complete();
                  }
                }
                if (bytes[1] == 0x81 &&
                    bytes[2] == _scanTransaction &&
                    bytes[4] == 2) {
                  _scanTimeout?.cancel();
                  _objects.clear();
                  _scanTransaction = 0;
                  _update(() {
                    _busy = false;
                    _message = provisioningError(bytes[5]);
                  });
                }
              } else if (bytes[1] == 0x82 &&
                  bytes[2] == _scanTransaction &&
                  bytes.length == 5) {
                _scanTimeout?.cancel();
                _objects.clear();
                _scanTransaction = 0;
                _update(() {
                  _busy = false;
                  _message = 'Scan complete: ${bytes[4]} networks reported.';
                });
              }
            } else {
              final type = bytes.length > 1 ? bytes[1] : 0;
              if (bytes.length < 3)
                throw const FormatException('Short data response');
              if (type == 2 &&
                  (_scanTransaction == 0 || bytes[2] != _scanTransaction))
                return;
              if (type == 3 &&
                  bytes[2] != 0 &&
                  bytes[2] != _credentialsTransaction) return;
              final object = _objects.add(bytes, bytes[2]);
              if (object == null) return;
              if (type == 2) {
                final network = WifiNetwork.decode(object);
                _update(() {
                  final previous = _networks[network.ssid];
                  if (previous == null || previous.rssi < network.rssi)
                    _networks[network.ssid] = network;
                });
              } else if (type == 3) {
                if (object.isEmpty ||
                    object[0] > 32 ||
                    object.length != object[0] + 6) {
                  throw const FormatException('Invalid network information');
                }
                // Network information contains no password.
                final network = WifiNetwork.decode([
                  0,
                  object.last,
                  0,
                  object[0],
                  ...object.sublist(1, 1 + object[0])
                ]);
                _update(() => _currentNetwork = network.ssid);
              }
            }
          } catch (_) {
            _update(() => _message =
                'Invalid provisioning response. Retry the operation.');
          }
        }, onError: (Object _) {
          _update(() {
            _available = false;
            _busy = false;
            _message = 'BLE provisioning disconnected. Reconnect to retry.';
          });
        }));
      }
      final bytes = await widget.transport.readStatus();
      if (_closed) return;
      _update(() {
        _status = WifiStatus.decode(bytes);
        _available = true;
        _message = _status!.state == 0
            ? 'Set up Wi-Fi? Scan nearby networks to begin.'
            : _status!.label;
      });
    } catch (error) {
      _update(() => _message = '$error');
    }
  }

  Future<void> _command(int opcode, int transaction) async {
    if (_closed) throw StateError('Wi-Fi settings closed.');
    final ack = Completer<void>();
    _ack = ack;
    _pendingOpcode = opcode;
    _pendingTransaction = transaction;
    // Attach the timeout/error handler before writing, because ACK can arrive during the write.
    final response = ack.future.timeout(const Duration(seconds: 10));
    try {
      await Future.wait<void>([
        widget.transport
            .write(provisioningControl, [1, opcode, transaction, 0]),
        response,
      ], eagerError: true);
    } finally {
      if (identical(_ack, ack)) _ack = null;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _update(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _update(() => _message = '$error');
    } finally {
      _update(() => _busy = false);
    }
  }

  Future<void> _security() async {
    final status = WifiStatus.decode(await widget.transport.readStatus());
    if (_closed) throw StateError('Wi-Fi settings closed.');
    _update(() => _status = status);
    if (status.encrypted != true) throw StateError(provisioningError(5));
  }

  Future<void> _scan() async {
    _update(() {
      _busy = true;
      _networks.clear();
      _message = 'Scanning nearby Wi-Fi networks…';
    });
    _objects.clear();
    _scanTransaction = _transaction();
    _scanTimeout?.cancel();
    _scanTimeout = Timer(const Duration(seconds: 60), () {
      _objects.clear();
      _scanTransaction = 0;
      _update(() {
        _busy = false;
        _message = 'Scan timed out. Try again.';
      });
    });
    try {
      await _command(2, _scanTransaction);
    } catch (error) {
      _scanTimeout?.cancel();
      _update(() {
        _busy = false;
        _message = '$error';
      });
    }
  }

  Future<void> _save() async {
    await _security();
    if (_ssid.text.isEmpty)
      throw const FormatException('Enter a network name.');
    final selected = _networks[_ssid.text];
    if (selected != null && !selected.supported)
      throw StateError(
          'Unsupported in this version. Select an Open, WPA2, or WPA3 personal network.');
    final object = credentialObject(_ssid.text, _password.text);
    final transaction = _transaction();
    _credentialsTransaction = transaction;
    try {
      await _command(3, transaction);
      for (final fragment in credentialFragments(transaction, object)) {
        try {
          if (_closed) throw StateError('Wi-Fi settings closed.');
          await widget.transport.write(provisioningData, fragment);
        } finally {
          fragment.fillRange(0, fragment.length, 0);
        }
      }
      await _command(4, transaction);
      _update(() => _message =
          'Credentials saved. Waiting for device connection status…');
    } catch (_) {
      try {
        await _command(6, transaction);
      } catch (_) {/* Firmware staging expires after 60 seconds. */}
      rethrow;
    } finally {
      object.fillRange(0, object.length, 0);
      if (!_closed) _password.clear();
    }
  }

  @override
  void dispose() {
    _closed = true;
    if (_ack != null && !_ack!.isCompleted)
      _ack!.completeError(StateError('Wi-Fi settings closed.'));
    if (_credentialsTransaction != 0 && _busy) {
      // Best effort cancellation on route close; firmware must also expire staging.
      unawaited(widget.transport.write(provisioningControl,
          [1, 6, _credentialsTransaction, 0]).catchError((Object _) {}));
    }
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _scanTimeout?.cancel();
    _objects.clear();
    _ssid.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final networks = _networks.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Scaffold(
        appBar: AppBar(title: const Text('Settings · Wi-Fi')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(_status?.label ?? 'Device Wi-Fi'),
          if (_currentNetwork.isNotEmpty)
            Text('Current network: $_currentNetwork'),
          if (_status?.state == 2) Text('IP address: ${_status!.ip}'),
          Text(_message),
          if (_status != null && !_status!.encrypted)
            const Text(
                'Pair the device with an encrypted BLE link to send or forget credentials.'),
          TextButton(
              onPressed: _available && !_busy ? _scan : null,
              child: const Text('Change network · Scan Wi-Fi')),
          TextButton(
              onPressed: _available && !_busy
                  ? () => _run(() async {
                        final status = WifiStatus.decode(
                            await widget.transport.readStatus());
                        _update(() {
                          _status = status;
                          _message = status.state == 3
                              ? provisioningError(
                                  status.error == 0 ? 10 : status.error)
                              : status.label;
                        });
                      })
                  : null,
              child: const Text('Refresh Wi-Fi status')),
          for (final network in networks)
            ListTile(
                title: Text(
                    network.ssid.isEmpty ? 'Hidden network' : network.ssid),
                subtitle: Text(
                    '${network.rssi} dBm · ${network.supported ? (network.auth == 0 ? 'Open' : 'Secured') : 'Unsupported in this version'}'),
                onTap: !_busy && network.supported
                    ? () => _update(() {
                          _ssid.text = network.ssid;
                          _password.clear();
                        })
                    : null),
          TextField(
              controller: _ssid,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'SSID')),
          TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                  labelText: 'Password (empty for open network)')),
          FilledButton(
              onPressed: _available && !_busy ? () => _run(_save) : null,
              child: const Text('Save and connect')),
          TextButton(
              onPressed: _available && !_busy
                  ? () => _run(() async {
                        await _security();
                        await _command(5, _transaction());
                        _password.clear();
                      })
                  : null,
              child: const Text('Forget network')),
          TextButton(
              onPressed: _available && !_busy
                  ? () => _run(() async {
                        await _command(
                            6,
                            _credentialsTransaction != 0
                                ? _credentialsTransaction
                                : _transaction());
                        _password.clear();
                      })
                  : null,
              child: const Text('Cancel provisioning')),
        ]));
  }
}
