import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'wifi_protocol.dart';
import 'wifi_transport.dart';

enum ProvisioningPhase {
  checkingStatus,
  ready,
  scanning,
  sendingCredentials,
  waitingForAcknowledgement,
  connectingToWifi,
  connected,
  failed,
  cancelling,
  cancelled,
  disconnected,
}

/// Owns the existing v1 transactions; never sends credentials to the API.
class WifiProvisioning extends ChangeNotifier {
  final ProvisioningTransport transport;
  final Duration commandTimeout, scanTimeout, connectionTimeout, pollInterval;
  WifiProvisioning(
    this.transport, {
    this.commandTimeout = const Duration(seconds: 10),
    this.scanTimeout = const Duration(seconds: 60),
    this.connectionTimeout = const Duration(seconds: 60),
    this.pollInterval = const Duration(seconds: 2),
  });
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _objects = ProvisioningObjects();
  final networks = <String, WifiNetwork>{};
  WifiStatus? status;
  WifiStatus? _resultStatus;
  bool _forgetting = false;
  String currentNetwork = '', requestedNetwork = '';
  String message = 'Reading device Wi-Fi status…';
  ProvisioningPhase phase = ProvisioningPhase.checkingStatus;
  bool available = false, credentialsAcknowledged = false;
  bool _closed = false, _polling = false, _commitStarted = false;
  bool _sawConnecting = false, _networkConfirmed = false;
  int _next = 0, _epoch = 0, _scanTransaction = 0, _credentialsTransaction = 0;
  int _pendingTransaction = 0, _pendingOpcode = 0;
  Completer<void>? _ack;
  Timer? _scanTimer, _connectionTimer, _pollTimer;
  bool get busy => [
        ProvisioningPhase.checkingStatus,
        ProvisioningPhase.scanning,
        ProvisioningPhase.sendingCredentials,
        ProvisioningPhase.waitingForAcknowledgement,
        ProvisioningPhase.connectingToWifi,
        ProvisioningPhase.cancelling
      ].contains(phase);
  bool get canCancel =>
      !_forgetting &&
      busy &&
      phase != ProvisioningPhase.checkingStatus &&
      phase != ProvisioningPhase.cancelling;
  int _transaction() => _next = _next % 255 + 1;
  void _emit() {
    if (!_closed) notifyListeners();
  }

  void _set(ProvisioningPhase value, String text) {
    if (_closed) return;
    phase = value;
    message = text;
    _emit();
  }

  void _check(int epoch) {
    if (_closed || epoch != _epoch || !available) {
      throw const ProvisioningFailure('Provisioning interrupted.');
    }
  }

  String _error(Object error) {
    if (error is ProvisioningFailure) return error.message;
    if (error is TimeoutException)
      return 'The ESP32 did not acknowledge the request in time. Retry.';
    return 'Unable to communicate with the ESP32. Reconnect and retry.';
  }

  Future<void> initialize() async {
    final epoch = ++_epoch;
    _set(ProvisioningPhase.checkingStatus, 'Reading device Wi-Fi status…');
    try {
      await transport.discover().timeout(commandTimeout);
      if (_closed || epoch != _epoch) return;
      _subscriptions.add(transport.disconnections.listen((_) => _disconnected(),
          onError: (Object _) => _disconnected()));
      for (final uuid in [
        provisioningControl,
        provisioningData,
        provisioningStatus
      ]) {
        _subscriptions.add(transport.subscribe(uuid).listen((bytes) {
          if (_closed || !available) return;
          try {
            if (uuid == provisioningStatus) {
              _acceptStatus(WifiStatus.decode(bytes));
            } else if (uuid == provisioningControl) {
              _control(bytes);
            } else {
              _data(bytes);
            }
          } catch (_) {
            message = 'Invalid provisioning response. Retry the operation.';
            _emit();
          }
        }, onError: (Object _) => _disconnected(), onDone: _disconnected));
      }
      available = true;
      final bytes = await transport.readStatus().timeout(commandTimeout);
      _check(epoch);
      _acceptStatus(WifiStatus.decode(bytes), refresh: true);
    } catch (error) {
      if (_closed || epoch != _epoch) return;
      available = false;
      _set(ProvisioningPhase.failed, _error(error));
    }
  }

  void _control(List<int> bytes) {
    if (bytes.length < 4 || bytes[0] != 1 || bytes.length != 4 + bytes[3]) {
      throw const FormatException('Invalid control response');
    }
    if (bytes[1] == 0x80 || bytes[1] == 0x81) {
      if (bytes.length != 6)
        throw const FormatException('Invalid acknowledgment');
      if (bytes[2] == _pendingTransaction &&
          bytes[4] == _pendingOpcode &&
          _ack != null &&
          !_ack!.isCompleted) {
        if (bytes[1] == 0x81 || bytes[5] != 0) {
          _ack!.completeError(ProvisioningFailure(provisioningError(bytes[5])));
        } else {
          // Record COMMIT acceptance synchronously: disconnect may follow this ACK.
          if (_pendingOpcode == 4) credentialsAcknowledged = true;
          _ack!.complete();
        }
      }
      if ((bytes[1] == 0x81 || bytes[5] != 0) &&
          bytes[2] == _scanTransaction &&
          bytes[4] == 2) {
        _endScan(provisioningError(bytes[5]), failed: true);
      }
    } else if (bytes[1] == 0x82 &&
        bytes.length == 5 &&
        _scanTransaction != 0 &&
        bytes[2] == _scanTransaction) {
      _endScan(networks.isEmpty
          ? 'No networks found. Refresh the scan or enter an SSID manually.'
          : 'Scan complete. Select a network or enter an SSID manually.');
    }
  }

  void _data(List<int> bytes) {
    if (bytes.length < 3) throw const FormatException('Short data response');
    final type = bytes[1];
    if (type == 2 && (_scanTransaction == 0 || bytes[2] != _scanTransaction))
      return;
    if (type == 3 && bytes[2] != 0 && bytes[2] != _credentialsTransaction)
      return;
    final object = _objects.add(bytes, bytes[2]);
    if (object == null) return;
    if (type == 2) {
      final network = WifiNetwork.decode(object);
      final previous = networks[network.ssid];
      if (previous == null || previous.rssi < network.rssi)
        networks[network.ssid] = network;
      _emit();
    } else if (type == 3) {
      if (object.isEmpty || object[0] > 32 || object.length != object[0] + 6) {
        throw const FormatException('Invalid network information');
      }
      currentNetwork = utf8.decode(object.sublist(1, 1 + object[0]));
      if (_commitStarted && currentNetwork == requestedNetwork)
        _networkConfirmed = true;
      if (credentialsAcknowledged && status != null) _connectionResult(status!);
      _emit();
    }
  }

  void _acceptStatus(WifiStatus value, {bool refresh = false}) {
    status = value;
    if (_commitStarted) _resultStatus = value;
    if (value.state == 0) currentNetwork = '';
    if (_commitStarted && value.state == 1) _sawConnecting = true;
    if (credentialsAcknowledged &&
        phase == ProvisioningPhase.connectingToWifi) {
      _connectionResult(value);
    } else if (refresh ||
        phase == ProvisioningPhase.ready ||
        phase == ProvisioningPhase.connected) {
      phase = value.state == 2
          ? ProvisioningPhase.connected
          : value.state == 3
              ? ProvisioningPhase.failed
              : ProvisioningPhase.ready;
      message = value.state == 0
          ? 'Set up Wi-Fi? Scan nearby networks to begin.'
          : value.state == 3
              ? provisioningError(value.error == 0 ? 10 : value.error)
              : value.label;
    }
    _emit();
  }

  void _connectionResult(WifiStatus value) {
    if (phase != ProvisioningPhase.connectingToWifi) return;
    if (value.state == 2 && (_sawConnecting || _networkConfirmed)) {
      _stopWaiting();
      _set(ProvisioningPhase.connected, 'Connected successfully.');
    } else if (value.state == 3 && _sawConnecting) {
      _stopWaiting();
      _set(ProvisioningPhase.failed,
          'Unable to connect to $requestedNetwork. ${provisioningError(value.error == 0 ? 10 : value.error)}');
    }
  }

  Future<void> _command(int opcode, int transaction) async {
    final ack = Completer<void>();
    _ack = ack;
    _pendingOpcode = opcode;
    _pendingTransaction = transaction;
    final response = ack.future.timeout(commandTimeout);
    try {
      await Future.wait<void>([
        transport.write(provisioningControl,
            [1, opcode, transaction, 0]).timeout(commandTimeout),
        response,
      ], eagerError: true);
    } finally {
      if (identical(_ack, ack)) _ack = null;
    }
  }

  Future<void> refresh() async {
    if (busy || !available) return;
    final epoch = _epoch;
    try {
      final value = await transport.readStatus().timeout(commandTimeout);
      _check(epoch);
      _acceptStatus(WifiStatus.decode(value), refresh: true);
    } catch (error) {
      if (!_closed && epoch == _epoch)
        _set(ProvisioningPhase.failed, _error(error));
    }
  }

  void _endScan(String text, {bool failed = false}) {
    _scanTimer?.cancel();
    _objects.clear();
    _scanTransaction = 0;
    _set(failed ? ProvisioningPhase.failed : ProvisioningPhase.ready, text);
  }

  Future<void> scan() async {
    if (busy || !available) return;
    final epoch = ++_epoch;
    _credentialsTransaction = 0;
    credentialsAcknowledged = false;
    _commitStarted = false;
    networks.clear();
    _objects.clear();
    _scanTransaction = _transaction();
    _set(ProvisioningPhase.scanning, 'Scanning nearby Wi-Fi networks…');
    _scanTimer = Timer(scanTimeout, () {
      _endScan('Scan timed out. Try again.', failed: true);
    });
    try {
      await _command(2, _scanTransaction);
    } catch (error) {
      if (!_closed && epoch == _epoch) _endScan(_error(error), failed: true);
    }
  }

  Future<void> _security(int epoch) async {
    final value =
        WifiStatus.decode(await transport.readStatus().timeout(commandTimeout));
    _check(epoch);
    status = value;
    _emit();
    if (!value.encrypted) throw ProvisioningFailure(provisioningError(5));
  }

  Future<void> provision(String ssid, String password) async {
    if (busy || !available) return;
    final epoch = ++_epoch;
    List<int>? object;
    _credentialsTransaction = 0;
    credentialsAcknowledged = false;
    _commitStarted = false;
    _sawConnecting = false;
    _networkConfirmed = false;
    _resultStatus = null;
    requestedNetwork = ssid;
    _set(ProvisioningPhase.sendingCredentials, 'Checking BLE security…');
    try {
      if (ssid.isEmpty)
        throw const ProvisioningFailure('Enter a network name.');
      final selected = networks[ssid];
      if (selected != null && !selected.supported) {
        throw const ProvisioningFailure(
            'Unsupported in this version. Select an Open, WPA2, or WPA3 personal network.');
      }
      if (selected != null && selected.auth != 0 && password.isEmpty) {
        throw const ProvisioningFailure(
            'Enter the password for this secured network.');
      }
      try {
        object = credentialObject(ssid, selected?.auth == 0 ? '' : password);
      } on FormatException catch (error) {
        throw ProvisioningFailure(error.message);
      }
      await _security(epoch);
      _credentialsTransaction = _transaction();
      _set(ProvisioningPhase.waitingForAcknowledgement,
          'Waiting for ESP32 to begin credential transfer…');
      await _command(3, _credentialsTransaction);
      _check(epoch);
      _set(ProvisioningPhase.sendingCredentials, 'Sending Wi-Fi credentials…');
      for (final fragment
          in credentialFragments(_credentialsTransaction, object)) {
        try {
          _check(epoch);
          await transport
              .write(provisioningData, fragment)
              .timeout(commandTimeout);
          _check(epoch);
        } finally {
          fragment.fillRange(0, fragment.length, 0);
        }
      }
      await _security(epoch);
      _commitStarted = true;
      _set(ProvisioningPhase.waitingForAcknowledgement,
          'Waiting for ESP32 credential acknowledgement…');
      await _command(4, _credentialsTransaction);
      _check(epoch);
      credentialsAcknowledged = true;
      _set(ProvisioningPhase.connectingToWifi,
          'ESP32 received credentials. Connecting ESP32 to $ssid…');
      _connectionTimer = Timer(connectionTimeout, () {
        _stopWaiting();
        _set(ProvisioningPhase.failed,
            'Connection status timed out. Credentials may already be saved. Refresh status before retrying.');
      });
      _pollTimer = Timer.periodic(pollInterval, (_) => _poll(epoch));
      if (_resultStatus != null) _connectionResult(_resultStatus!);
    } catch (error) {
      if (!_closed && epoch == _epoch) {
        final text = _error(error);
        if (_credentialsTransaction != 0 &&
            available &&
            !credentialsAcknowledged) {
          try {
            await _command(6, _credentialsTransaction);
          } catch (_) {}
        }
        if (!_closed && epoch == _epoch) _set(ProvisioningPhase.failed, text);
      }
    } finally {
      object?.fillRange(0, object.length, 0);
    }
  }

  Future<void> _poll(int epoch) async {
    if (_polling ||
        _closed ||
        epoch != _epoch ||
        phase != ProvisioningPhase.connectingToWifi) return;
    _polling = true;
    try {
      final bytes = await transport.readStatus().timeout(commandTimeout);
      if (!_closed &&
          epoch == _epoch &&
          phase == ProvisioningPhase.connectingToWifi) {
        _acceptStatus(WifiStatus.decode(bytes));
      }
    } catch (_) {
      // Missing reads do not prove disconnect; notifications/deadline decide.
    } finally {
      _polling = false;
    }
  }

  void _stopWaiting() {
    _connectionTimer?.cancel();
    _pollTimer?.cancel();
  }

  Future<void> forget() async {
    if (busy || !available) return;
    _forgetting = true;
    _credentialsTransaction = 0;
    credentialsAcknowledged = false;
    _commitStarted = false;
    final epoch = ++_epoch;
    _set(ProvisioningPhase.waitingForAcknowledgement,
        'Forgetting Wi-Fi credentials…');
    try {
      await _security(epoch);
      await _command(5, _transaction());
      _check(epoch);
      _set(ProvisioningPhase.ready,
          'Wi-Fi credentials cleared. Checking device status…');
      await refresh();
    } catch (error) {
      if (!_closed && epoch == _epoch)
        _set(ProvisioningPhase.failed, _error(error));
    } finally {
      _forgetting = false;
      _emit();
    }
  }

  Future<void> cancel() async {
    if (_forgetting) return;
    if (_closed || phase == ProvisioningPhase.cancelling) return;
    if (!busy) {
      _set(ProvisioningPhase.cancelled,
          'Wi-Fi setup cancelled. Stored credentials were not changed.');
      return;
    }
    final acknowledged = credentialsAcknowledged;
    final transaction = _credentialsTransaction;
    final epoch = ++_epoch;
    _scanTimer?.cancel();
    _scanTransaction = 0;
    _objects.clear();
    _stopWaiting();
    if (_ack != null && !_ack!.isCompleted) {
      _ack!.completeError(const ProvisioningFailure('Provisioning cancelled.'));
    }
    _set(ProvisioningPhase.cancelling, 'Cancelling provisioning…');
    bool confirmed = true;
    if (!acknowledged && transaction != 0 && available) {
      try {
        await _command(6, transaction);
      } catch (_) {
        confirmed = false;
      }
    }
    if (!_closed && epoch == _epoch) {
      _set(
          ProvisioningPhase.cancelled,
          acknowledged
              ? 'Stopped waiting. Credentials are already saved; this does not disconnect Wi-Fi.'
              : _commitStarted
                  ? 'Stopped waiting for acknowledgement. COMMIT was already sent; credentials may be saved. Refresh status before retrying.'
                  : confirmed
                      ? 'Provisioning cancelled.'
                      : 'Stopped sending. ESP32 cancellation was not confirmed; staging expires after 60 seconds. A submitted COMMIT may already have saved credentials.');
    }
  }

  void _disconnected() {
    if (_closed || !available) return;
    final acknowledged = credentialsAcknowledged;
    ++_epoch;
    available = false;
    _scanTimer?.cancel();
    _stopWaiting();
    if (_ack != null && !_ack!.isCompleted) {
      _ack!.completeError(const ProvisioningFailure('BLE disconnected.'));
    }
    _set(
        ProvisioningPhase.disconnected,
        acknowledged
            ? 'BLE disconnected after credentials were acknowledged. Wi-Fi may still connect; reconnect and refresh status. Credentials will not be resent automatically.'
            : 'BLE disconnected before acknowledgement. Provisioning was interrupted; reconnect and check status before retrying.');
  }

  @override
  void dispose() {
    final cancelStaging = !credentialsAcknowledged &&
        _credentialsTransaction != 0 &&
        busy &&
        available;
    _closed = true;
    ++_epoch;
    _scanTimer?.cancel();
    _stopWaiting();
    if (_ack != null && !_ack!.isCompleted)
      _ack!.completeError(const ProvisioningFailure('Wi-Fi settings closed.'));
    if (cancelStaging) {
      unawaited(transport
          .write(provisioningControl, [1, 6, _credentialsTransaction, 0])
          .timeout(commandTimeout)
          .catchError((Object _) {}));
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _objects.clear();
    super.dispose();
  }
}
