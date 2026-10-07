import 'dart:async';
import 'package:flutter/material.dart';
import 'wifi_transport.dart';
import 'wifi_protocol.dart';
import 'wifi_provisioning.dart';

class DeviceWifiSettings extends StatefulWidget {
  final ProvisioningTransport transport;
  const DeviceWifiSettings({super.key, required this.transport});
  @override
  State<DeviceWifiSettings> createState() => _DeviceWifiSettingsState();
}

class _DeviceWifiSettingsState extends State<DeviceWifiSettings> {
  late final WifiProvisioning _provisioning =
      WifiProvisioning(widget.transport);
  final _ssid = TextEditingController(), _password = TextEditingController();
  final _ssidFocus = FocusNode();
  bool _showPassword = false, _confirming = false;
  @override
  void initState() {
    super.initState();
    _provisioning.addListener(_changed);
    unawaited(_provisioning.initialize());
  }

  void _changed() {
    if (!mounted) return;
    if (_provisioning.phase == ProvisioningPhase.disconnected) _clearPassword();
    setState(() {});
  }

  void _clearPassword() {
    _password.clear();
    _showPassword = false;
  }

  Future<void> _submit() async {
    if (_confirming || _provisioning.busy) return;
    final ssid = _ssid.text;
    final selected = _provisioning.networks[ssid];
    String? validation;
    List<int>? object;
    try {
      if (ssid.isEmpty)
        validation = 'Enter a network name.';
      else if (selected != null &&
          selected.auth != 0 &&
          _password.text.isEmpty) {
        validation = 'Enter the password for this secured network.';
      } else {
        object =
            credentialObject(ssid, selected?.auth == 0 ? '' : _password.text);
      }
    } on FormatException catch (error) {
      validation = error.message;
    } finally {
      object?.fillRange(0, object.length, 0);
    }
    if (validation != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(validation)));
      return;
    }
    setState(() {
      _confirming = true;
      _showPassword = false;
    });
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text('Connect ESP32 to "$ssid"?'),
              content: const Text(
                  'The Wi-Fi credentials will be sent directly to the ESP32 over encrypted Bluetooth.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Connect')),
              ],
            ));
    if (!mounted) return;
    setState(() => _confirming = false);
    if (confirmed != true) {
      _clearPassword();
      await _provisioning.cancel();
      return;
    }
    final password = _password.text;
    _clearPassword();
    setState(() {});
    await _provisioning.provision(ssid, password);
  }

  @override
  void dispose() {
    _provisioning.removeListener(_changed);
    _provisioning.dispose();
    _ssid.dispose();
    _clearPassword();
    _password.dispose();
    _ssidFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = _provisioning;
    final enabled = model.available && !model.busy && !_confirming;
    final networks = model.networks.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    final selected = model.networks[_ssid.text];
    final open = selected?.auth == 0;
    return Scaffold(
        appBar: AppBar(title: const Text('Settings · Wi-Fi')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(model.status?.label ?? 'Device Wi-Fi'),
          if (model.currentNetwork.isNotEmpty)
            Text(
                '${model.status?.state == 2 ? 'Connected to' : 'Last reported network'}: ${model.currentNetwork}'),
          if (model.status?.state == 2 && model.status!.ip != '0.0.0.0')
            Text('IP address: ${model.status!.ip}'),
          Semantics(liveRegion: true, child: Text(model.message)),
          if (model.busy)
            const Icon(Icons.hourglass_top,
                semanticLabel: 'Provisioning in progress'),
          if (model.status != null && !model.status!.encrypted)
            const Text(
                'Pair the device with an encrypted BLE link to send or forget credentials. Complete OS pairing, then refresh Wi-Fi status.'),
          TextButton(
              onPressed: enabled ? model.scan : null,
              child: Text(model.status?.state == 2
                  ? 'Change network · Scan Wi-Fi'
                  : 'Set Up Wi-Fi · Scan Wi-Fi')),
          TextButton(
              onPressed: enabled ? model.refresh : null,
              child: const Text('Refresh Wi-Fi status')),
          for (final network in networks)
            ListTile(
              title:
                  Text(network.ssid.isEmpty ? 'Hidden network' : network.ssid),
              subtitle: Text(
                  '${network.rssi} dBm · ${network.supported ? (network.auth == 0 ? 'Open' : 'Secured') : 'Unsupported in this version'}'),
              onTap: enabled && network.supported
                  ? () => setState(() {
                        _ssid.text = network.ssid;
                        _clearPassword();
                        _ssidFocus.requestFocus();
                      })
                  : null,
            ),
          TextButton(
              onPressed: enabled
                  ? () => setState(() {
                        _ssid.clear();
                        _clearPassword();
                        _ssidFocus.requestFocus();
                      })
                  : null,
              child: const Text('Other Network / Enter SSID Manually')),
          TextField(
              controller: _ssid,
              focusNode: _ssidFocus,
              enabled: enabled,
              onChanged: (_) => setState(_clearPassword),
              decoration: const InputDecoration(labelText: 'SSID')),
          if (open) const Text('Open network: no password required.'),
          TextField(
              controller: _password,
              enabled: enabled && !open,
              obscureText: !_showPassword,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                  labelText: open
                      ? 'No password required'
                      : 'Password (empty for open network)',
                  suffixIcon: IconButton(
                      onPressed: enabled && !open
                          ? () => setState(() => _showPassword = !_showPassword)
                          : null,
                      tooltip:
                          _showPassword ? 'Hide password' : 'Show password',
                      icon: Icon(_showPassword
                          ? Icons.visibility_off
                          : Icons.visibility)))),
          FilledButton(
              onPressed: enabled ? _submit : null,
              child: const Text('Save and connect')),
          TextButton(
              onPressed: enabled
                  ? () async {
                      _clearPassword();
                      await model.forget();
                    }
                  : null,
              child: const Text('Forget network')),
          TextButton(
              onPressed: model.canCancel || enabled
                  ? () async {
                      _clearPassword();
                      await model.cancel();
                    }
                  : null,
              child: Text(model.credentialsAcknowledged && model.busy
                  ? 'Stop waiting for connection'
                  : 'Cancel provisioning')),
        ]));
  }
}
