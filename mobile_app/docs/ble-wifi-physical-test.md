# Flutter BLE Wi-Fi workflow and physical test

## What existed already

`lib/device_connections.dart` discovers BatteryMonitor using the unchanged
measurement service, owns the BLE connection and measurement subscription, and
opens `DeviceWifiSettings`. `lib/wifi_transport.dart` owns provisioning GATT access.
`lib/wifi_protocol.dart` defines the v1 UUIDs, status/scan decoding, UTF-8 limits,
13-byte credential fragments and response reassembly. The former settings widget
already performed BEGIN/Data/COMMIT, matched transaction IDs/opcodes, checked
link encryption, scanned, forgot networks and attempted cancellation. Existing
protocol and widget tests covered those contracts.

The gaps were user confirmation, password visibility control, explicit manual
entry, cancellation while busy, post-COMMIT result waiting/polling, bounded
connection waiting, safe error presentation and phase-aware disconnect handling.

## What changed / files changed

- `lib/wifi_provisioning.dart`: controller for the existing byte protocol,
  notifications, command matching, phases, result deadline, status polling,
  active cancellation and disconnect handling.
- `lib/wifi_settings.dart`: presentation and ephemeral credential fields;
  confirmation, show/hide, manual entry, open-network handling and progress.
- `lib/wifi_transport.dart`: safe transport errors and device-disconnect events.
- `lib/wifi_protocol.dart`: separate existing error 0x0B timeout text from 0x0A.
- `test/support/provisioning_fake.dart`: reusable fake radio/ESP32 boundary.
- `test/wifi_settings_test.dart`: preserve existing regression scenarios with
  the new confirmation step.
- `test/wifi_provisioning_test.dart`, `test/wifi_workflow_test.dart`: controller
  and screen coverage of the end-to-end logical workflow and timing failures.
- This guide, `docs/ble-wifi-provisioning-v1.md` and `docs/verification.md`: integration/acceptance guidance and verification evidence.

Architecture: Device connections -> Wi-Fi settings -> WifiProvisioning controller
-> ProvisioningTransport -> the existing v1 Control/Data/Status characteristics.
Credentials never pass through the HTTP API, capture log or PostgreSQL.
Measurement subscriptions, packet layouts and capture/storage code are unchanged.

## How the user provisions Wi-Fi now

Open Device connections, scan for BatteryMonitor, select it, and complete OS BLE
pairing as required by the firmware. Settings / Wi-Fi opens automatically; it can
also be reopened from the connected-device page. Refresh status after pairing.
Choose Set Up Wi-Fi or Change network / Scan Wi-Fi. The ESP32 performs the scan;
the phone displays its results, consolidating duplicate SSIDs by strongest RSSI.
Unsupported security modes are shown but cannot be selected. Empty scans and
scan failures permit another scan or manual SSID entry.

Select a network or choose Other Network / Enter SSID Manually. A selected open
network disables the password field and sends an empty password. A selected
secured network requires a password. Manual SSIDs allow an empty password for
an open/hidden network; the device validates the actual authentication mode.
Passwords start obscured and have a Show/Hide button.

Save and connect opens `Connect ESP32 to "<SSID>"?` without showing the password.
Cancel clears the entered password and performs no credential write. Connect
clears the password field immediately, sends the existing fragments, waits for
COMMIT ACK and displays the connection result/IP. The controller does not retain
the password as a field. Mutable credential/fragment buffers are overwritten.
Dart strings and OS/plugin copies cannot guarantee secure erasure.

During sending, Cancel provisioning invalidates the attempt and tries CANCEL
with the same transaction ID. No further fragments or COMMIT are dispatched by
that attempt after cancellation is observed. A BLE write already dispatched
cannot be withdrawn. An unconfirmed CANCEL explicitly reports that uncertainty
and the firmware staging-expiry requirement. If COMMIT was already sent, even
a confirmed CANCEL does not prove that saving was prevented; the UI asks the
user to refresh status. Cancelling a scan stops local observation; v1 CANCEL
discards credential staging and does not define a Wi-Fi scan-abort command.

After acknowledged COMMIT, Stop waiting for connection stops observation only;
it does not erase saved credentials or disconnect Wi-Fi. Use Forget network to
send CLEAR_CREDENTIALS. Neither cancellation nor failure automatically resends
credentials. A disconnect before ACK reports interruption; after COMMIT ACK it
reports that Wi-Fi may still connect and asks the user to reconnect/refresh.

## BLE messages involved

All UUIDs below are exact and preserve the supplied PDF's protocol:

| Role | UUID | Required properties |
| --- | --- | --- |
| Service | `5ecf1000-41c2-4cc4-9c96-640f406021d0` | Service |
| Control | `5ecf1001-41c2-4cc4-9c96-640f406021d0` | WRITE, NOTIFY |
| Data | `5ecf1002-41c2-4cc4-9c96-640f406021d0` | WRITE, NOTIFY |
| Status | `5ecf1003-41c2-4cc4-9c96-640f406021d0` | READ, NOTIFY |

Control request: `[0x01, opcode, transactionId, 0x00]`.
IDs are 1..255; zero is reserved for unsolicited notifications.

| Opcode | Meaning |
| --- | --- |
| `0x01` | GET_STATUS; optional synchronization command, normal client reads Status |
| `0x02` | START_SCAN |
| `0x03` | BEGIN_CREDENTIALS |
| `0x04` | COMMIT_CREDENTIALS; same ID as BEGIN and credential fragments |
| `0x05` | CLEAR_CREDENTIALS |
| `0x06` | CANCEL; discard staging, preserve previously stored credentials |
| `0x80` | ACK: `[1, 0x80, id, 2, originalOpcode, resultCode]` |
| `0x81` | ERROR: `[1, 0x81, id, 2, originalOpcode, errorCode]` |
| `0x82` | SCAN_DONE: `[1, 0x82, scanId, 1, reportedNetworkCount]` |

The ACK must match both transaction ID and original command opcode. A BEGIN ACK
accepts staging; successful COMMIT ACK acknowledges credential acceptance/save,
not successful Wi-Fi association. The client gives each command/write 10 seconds.
Scans and partial response objects expire after 60 seconds.

Data packet: `[1, type, transactionId, objectId, offset, totalLength,
chunkLength, ...chunk]`, with at most 13 bytes/chunk and 20 bytes/write at MTU 23.

- `0x01 WIFI_CREDENTIALS`: `[ssidByteLength, passwordByteLength,
  ...ssidUtf8, ...passwordUtf8]`; SSID <=32 bytes, password <=63 bytes.
- `0x02 SCAN_RESULT`: `[resultIndex, signedRssiByte, authType,
  ssidByteLength, ...ssidUtf8]`; uses the active scan ID.
- `0x03 NETWORK_INFO`: `[ssidByteLength, ...ssidUtf8, ip1, ip2, ip3, ip4,
  signedRssiByte]`; accepts the active credential ID or unsolicited ID zero.
  Supplies the actual network name, never a password.

Status: `[1, state, flags, lastError, ip1, ip2, ip3, ip4]`.
States: `0 UNPROVISIONED`, `1 CONNECTING`, `2 CONNECTED`, `3 CONNECTION_FAILED`.
Flag bits: 0 stored credentials, 1 scan active, 2 transaction active,
3 encrypted BLE link. IPv4 `0.0.0.0` means unavailable and is not displayed as
an assigned address.

After COMMIT ACK the client watches notifications, polls Status every 2 seconds
without overlapping reads, and stops waiting after 60 seconds. This is a client
observation deadline, not a change to firmware connection timing. A new attempt
must observe CONNECTING before a terminal status, or a matching NETWORK_INFO
for success, to avoid declaring the previous network's CONNECTED state a success.
Refresh after a deadline explicitly reads the current device state without resend.

## Security behavior

The client rereads Status and requires encrypted flag bit 3 before BEGIN and
again before COMMIT; CLEAR also requires a fresh encrypted-link check. Disconnect
invalidates the operation. Firmware must enforce encryption independently for
BEGIN, all credential Data writes, COMMIT and CLEAR, and enforce authenticated
pairing for the final product. The Flutter plugin uses OS pairing; the client
cannot establish authenticated pairing merely by checking this single flag.

Passwords are not logged, placed in URLs, saved in application preferences,
session records or PostgreSQL. Transport exceptions are sanitized so BLE write
arguments cannot reach the normal UI. Fields are cleared on accepted submission,
confirmation cancellation, active cancellation, forgetting, disconnect and exit.

## Protocol limits / blockers

The current documented linked firmware supports GET_STATUS and START_SCAN;
BEGIN/Data credential writes/COMMIT/CLEAR/CANCEL remain firmware integration work.
No firmware is modified, built or flashed by this application task.

Protocol v1 has `0x08 Invalid password`, `0x0A Connection failed` and
`0x0B Connection timeout`. It has no distinct authentication-failure or
network-not-found reason. The app displays invalid-password rejection or timeout
when those are reported; for 0x0A it says to check the password and network,
without guessing which failed. Precise authentication-versus-missing-network
reporting is blocked by the existing firmware/protocol result granularity and
needs a separately agreed compatible extension, not an invented client opcode.

Status does not include the SSID. On an already-connected device the actual SSID
can only be shown if the ESP32 supplies NETWORK_INFO. Its IP remains available
from Status. Emitting unsolicited NETWORK_INFO after subscriptions or status
synchronization is useful for an already-connected device, but is not an extra
request type invented by this client.

The existing direct connection page is Android-oriented and uses its native
connectivity/permission bridge. Android is the physical-test target here. iOS
source exists, but its direct-connection bridge, Bluetooth permissions, build and
physical pairing need separate validation on macOS/iPhone. Web previews cannot
prove native BLE radio behavior.

## ESP32 requirements for physical test

1. Advertise the existing BatteryMonitor measurement service so discovery can
   find the board; expose the separate provisioning service and all properties.
2. Complete OS pairing, accurately report encrypted flag bit 3, and reject
   sensitive commands/Data on an insecure link with error 0x05. Independently
   enforce authenticated pairing for final firmware.
3. Return the 8-byte v1 Status on read and notify every state transition.
4. ACK START_SCAN, perform an asynchronous board-side scan, send SCAN_RESULT
   objects/fragments with the scan ID, and finish with SCAN_DONE or ERROR.
5. ACK BEGIN, allocate bounded RAM staging and validate transaction/object IDs,
   lengths, offsets and duplicate/conflicting fragments. Do not write NVS yet.
6. Accept type-0x01 credential fragments at MTU 23. COMMIT must validate the
   complete object, save via the existing WiFiManager / wifi_cfg NVS API,
   ACK the matching command, and initiate asynchronous Wi-Fi connection.
7. Notify CONNECTING for the new attempt, then CONNECTED with assigned IPv4 or
   CONNECTION_FAILED with the applicable v1 error. Keep BLE available on failure
   and allow replacement credentials. NETWORK_INFO supplies the actual SSID.
8. CANCEL must discard/wipe staging and leave previously saved NVS credentials
   intact. Expire/wipe incomplete staging after about 60 seconds, including
   interrupted BLE transfers. Report errors without passwords or raw fragments.
9. CLEAR must erase credentials through the existing API, disconnect Wi-Fi,
   acknowledge the command and report UNPROVISIONED.
10. On reboot use saved credentials to reconnect. Scans, provisioning, failures
    and recovery must leave the existing acquisition/queues/measurement protocol
    and 1 kHz timer independent and functioning normally.

## Exact physical test procedure

Prerequisite: the firmware owner supplies a flashed v1-compatible board; this
procedure does not authorize this app task to modify/build/flash firmware.
Use an Android phone, a reachable personal-network router, a second network,
and a known open test network if available. Keep the phone app in the foreground.
API/database login is only needed for measurement storage, not BLE credentials.

1. Install/open an Android build containing these changes; enable Bluetooth.
2. Power the board and open Device connections / BLE / Scan for ESP32.
3. Grant requested Android permissions and select BatteryMonitor.
4. Complete the firmware's OS pairing procedure. Settings / Wi-Fi opens.
5. Refresh Wi-Fi status. On a fresh board expect UNPROVISIONED; confirm the
   encrypted-link warning clears before submitting credentials.
6. Choose Set Up Wi-Fi / Scan Wi-Fi. Confirm scanning progress and router SSID,
   RSSI/security, sorted results and strongest-signal duplicate consolidation.
7. Select the router, enter its password, optionally show/hide it, and choose
   Save and connect. Confirm the dialog shows the SSID and no password.
8. Choose Cancel once. Verify the field clears and the board receives no BEGIN.
   Re-enter credentials and choose Save and connect / Connect.
9. Observe BEGIN ACK, fragmented Data and matching COMMIT ACK using safe firmware
   counters/logs that omit credential bytes. The field clears immediately.
10. Observe the received-credentials/connecting message, then Connected
    successfully and the assigned IPv4. Verify the IP against the router client
    list. Verify the actual SSID if NETWORK_INFO is emitted.
11. Power-cycle the board, reconnect BLE and refresh. Confirm automatic Wi-Fi
    reconnection with stored credentials, without re-entering the password.
12. Change network / Scan Wi-Fi, select a second router and repeat. Confirm the
    new credentials replace the old ones without a preceding CLEAR.
13. Test Other Network / Enter SSID Manually, including a hidden test SSID.
14. Test a known open network; verify no password is required or sent.
15. Test an intentionally incorrect password. Expect CONNECTION_FAILED; 0x0A
    cannot distinguish authentication failure from unavailable SSID. Correct the
    password and retry in the same app without restarting it.
16. Test an absent SSID/router outage and restoration; check general failure or
    0x0B timeout as firmware reports, while BLE remains usable.
17. Cancel during BEGIN/Data. Confirm no further fragments/COMMIT are sent after
    cancellation is observed, staging is wiped/expired, and old NVS is intact.
18. Disconnect BLE before COMMIT ACK; expect interrupted/unknown outcome. After
    60 seconds reconnect/refresh, and verify incomplete staging expired safely.
19. Disconnect immediately after COMMIT ACK. Expect the acknowledged/unknown
    outcome message, no credential resend, and accurate status after reconnect.
20. Delay/suppress the final status notification: verify polling recovers a
    reported result, or the 60-second observation deadline offers refresh/retry.
21. Choose Forget network; verify CLEAR ACK, UNPROVISIONED, Wi-Fi disconnection,
    and no automatic reconnection after power-cycle until reprovisioned.
22. Repeat sensitive operations on an unencrypted link; verify both client and
    firmware reject them. Inspect safe logs for absence of password bytes.
23. During these operations have the firmware owner check acquisition timing,
    queue/counter behavior and measurement continuity against PDF section 27.
    App tests do not establish 1 kHz hardware, NVS or authenticated-pairing success.

## Tests run and results

The app-side tests use the fake transport; none claim physical ESP32 success.
On October 6, 2026 the final full Flutter suite passed all **92 tests**, including
**43 provisioning tests** (23 controller, 8 workflow UI, 7 existing settings and
5 protocol). Final Dart analysis reported **no issues**, and the formatter check
reported **8 files / 0 changes**. Cases include stale ACKs, cancellation during
sending and after dispatched COMMIT, immediate ACK/disconnect races, status
polling/deadlines, encryption loss, byte cleanup, confirmation and retry.

An Android debug APK build was attempted but stopped because this checkout has
**no Android SDK installed**. No updated APK or phone radio success is claimed.
Run `executables/00B_First_Time_Android_Setup.cmd`, then the existing Android build
launcher to prepare the physical test. The final suite also preserved capture,
accounts, history, deletion and shared measurement/provisioning contracts. Run from `mobile_app/`:

```powershell
.\.tools\flutter\bin\dart.bat format lib/wifi_protocol.dart lib/wifi_provisioning.dart lib/wifi_settings.dart lib/wifi_transport.dart test/wifi_protocol_test.dart test/wifi_provisioning_test.dart test/wifi_settings_test.dart test/wifi_workflow_test.dart test/support/provisioning_fake.dart
.\.tools\flutter\bin\flutter.bat test --no-pub
.\.tools\flutter\bin\flutter.bat analyze --no-pub
```