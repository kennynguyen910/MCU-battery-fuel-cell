# Provisioning v1 firmware acceptance

These tests are a procedure, not a record of hardware success. Run on ESP32 and
ESP32-S3 with the existing Flutter Android app and nRF Connect for malformed
writes. Capture serial diagnostics and phone Control/Data/Status notifications.
Never capture real passwords or password-bearing packets in shared logs.

## Setup

Use a disposable 2.4 GHz Open/WPA2/WPA3-personal router and test credentials.
Keep WIFI_ENABLE_DEVELOPMENT_SEED and BATTERY_MONITOR_ALLOW_INSECURE_PROVISIONING_DEV
at zero. Fresh configs must have NimBLE security, Secure Connections only, and
NVS bond persistence enabled (see sdkconfig.defaults). For existing sdkconfig,
enable CONFIG_BT_NIMBLE_SM_SC_ONLY=1 and CONFIG_BT_NIMBLE_NVS_PERSIST=y explicitly.
Use the serial monitor at 115200 baud, connect to BatteryMonitor, and enter the
fresh six-digit serial pairing code in the phone's OS dialog. Subscribe to all
three provisioning characteristics. GET_STATUS is `01 01 01 00`; its ACK is
`01 80 01 02 01 00`. Status is exactly eight bytes and bit 3 reflects encryption.

Use these fictional credentials only: TestWiFi / example123. They work on a
router only if you deliberately configure that disposable router to match.

```
BEGIN Control: 01 03 10 00
fragment A Data: 01 01 10 00 00 14 0D 08 0A 54 65 73 74 57 69 46 69 65 78 61
fragment B Data: 01 01 10 00 0D 14 07 6D 70 6C 65 31 32 33
COMMIT Control: 01 04 10 00
CANCEL Control: 01 06 10 00
CLEAR Control: 01 05 12 00
```

ACKs are `[01,80,transaction,02,command,00]`; errors are
`[01,81,transaction,02,command,error]`. Data errors echo BEGIN (03).
Restart with BEGIN after any malformed Data or rejected COMMIT. Repeat-pairing
requests do not silently replace an existing bond: retain the bond on the phone
for reboot tests. If the phone loses its bond, remove that peer's device-side bond
through a deliberate development maintenance procedure before re-pairing.

## Credential and lifecycle cases

| Case | Procedure | Required result |
| --- | --- | --- |
| 1 BEGIN creates staging | Send BEGIN, read status | Matching 03 ACK; transaction bit set; existing Wi-Fi/NVS unchanged |
| 2 Reassembly | BEGIN, B then A; repeat A identically | ATT write responses; no Data ACK; complete object can COMMIT |
| 3 Invalid fragment | BEGIN/A, change a byte in overlapping A and resend | ERROR 0E, staging cleared; subsequent COMMIT gets 0C |
| 4 Oversize | BEGIN, set total to 62 hex (98); separately send a 14-byte chunk | ERROR 0E, no NVS change; no crash |
| 5 Wrong transaction | BEGIN/A, send B with transaction 11 | ERROR 0D for 11/03; staging cleared |
| 6 No BEGIN | On idle send COMMIT | ERROR 0C for 10/04, no ACK or NVS write |
| 7 Incomplete | BEGIN/A then COMMIT | ERROR 0C, staging cleared, no NVS write |
| 8 Persistent commit | BEGIN/A/B/COMMIT with matching router | Credentials saved; stored bit set; no password/payload logged |
| 9 Correct ACK/order | Record case 8 notifications and serial output | COMMIT ACK is 01 80 10 02 04 00 after save, before connection begins; CONNECTING then CONNECTED/IP and unsolicited NETWORK_INFO with SSID/IP/RSSI |
| 10 CANCEL wipes staging | BEGIN/A/CANCEL then COMMIT | CANCEL ACK 01 80 10 02 06 00; flag clears; COMMIT gets 0C |
| 11 CANCEL preserves NVS | First provision router, then run case 10 and reboot | Original router reconnects without provisioning |
| 12 Timeout wipes staging | BEGIN/A, no writes for over 60 s | ERROR 0B for 10/03, transaction bit clears; COMMIT gets 0C |
| 13 CLEAR removes NVS | After success, send CLEAR | Wi-Fi stops; keys deleted; matching 05 ACK; UNPROVISIONED, no stored flag/IP; reboot stays unprovisioned |
| 14 Reboot reload | After valid COMMIT ACK, reboot without erase | Saved credentials load, CONNECTING then CONNECTED/IP, no phone needed |
| 15 Security gate | Before pairing completes, send BEGIN, Data, COMMIT, CLEAR | ERROR 05 for each command (Data echoes 03); NVS unchanged; encrypted unauthenticated peer also rejected |
| 16 Disconnect before COMMIT | BEGIN/A, disconnect, reconnect, then COMMIT | Staging gone; ERROR 0C; original persisted credentials unchanged |
| 17 Disconnect after ACK | BEGIN/A/B/COMMIT, disconnect immediately after 04 ACK | Wi-Fi apply continues; saved credentials survive reboot |
| 18 Replace staging | BEGIN 10/A, then BEGIN 11 | New matching BEGIN ACK; old bytes wiped; COMMIT 10 rejected; transfer for 11 succeeds |
| 19 UTF-8 | Send overlong C0 80 SSID; separately a surrogate ED A0 80 password; test valid multibyte values | Invalid SSID gets 07, invalid password gets 08; valid UTF-8 accepted within byte limits |
| 20 Open/manual SSID | Provision an open network with password length zero; provision manually entered SSID without scanning | Both accepted; scan membership is not required |
| 21 COMMIT error | On a disposable instrumented build, make saveCredentials return false before NVS writes | Matching ERROR 09 for 04, no success ACK, no Wi-Fi apply; staged and worker copies wiped |
| 22 CLEAR error | On a disposable instrumented build, make clearCredentials return false | Matching ERROR 09 for 05, no success ACK; recover by valid CLEAR after restoring code |
| 23 Lost ACK window | Disconnect after submitted COMMIT but before observing ACK | No old response reaches the new session; queued work is cancelled before NVS starts; in-flight NVS may finish, so inspect stored state/reboot before retry |

Cases 21/22 describe fault injection only; restore those temporary changes before
the normal build. They have not been executed here. Inspect staging and worker
buffers with a debugger when verifying erasure; never print them. Framework-owned
NimBLE, Wi-Fi, and NVS buffers have their own lifetimes.

## Radio and acquisition regression

1. START_SCAN `01 02 20 00` must ACK with transaction 20/opcode 02, deliver type-02
   objects, then `01 82 20 01 count`. Check SSID, signed RSSI, and authentication
   mapping for Open/WPA2/WPA3/unsupported modes. Duplicate SSIDs keep the strongest
   candidate. A 32-byte name fragments as 13/13/10 bytes. No APs is count zero.
   Scan candidate storage is capped at 15; a connection in progress reports BUSY.
2. Wrong password and unavailable router must produce CONNECTING then
   CONNECTION_FAILED/error 0A. Restore the router; existing reconnect policy
   must recover. Replace failed credentials through the app without CLEAR first.
3. GET_STATUS and status READ remain usable during staging/NVS/apply. A second
   BLE client must not replace the first client's staging or subscriptions.
4. Run `python tools/udp_receiver.py` from firmware/ and monitor existing five-second
   serial acquisition diagnostics while scanning, saving, reconnecting, and clearing.
   Record frame rate near 1000/s, lateness/missed deadlines, ADC errors, queue drops,
   UDP gaps, and recovery. Flash writes/radio coexistence require physical timing
   evidence. No new code gates acquisition on network state.
5. Verify original measurement service UUIDs, 80-byte voltage packets, and 10 Hz
   notifications at MTU >=83. Repeat provisioning at default MTU 23. The current
   source uses FakeADC and has no compiled OLED task; physical ADC/OLED acceptance
   remains separate integration work.

## Build-only verification

From firmware/ in an ESP-IDF 5.5.5 terminal, use isolated configurations so the
existing development-board config is preserved:

```
idf.py -B build/provisioning-esp32s3 -D SDKCONFIG=build/provisioning-esp32s3/sdkconfig -D IDF_TARGET=esp32s3 build
idf.py -B build/provisioning-esp32 -D SDKCONFIG=build/provisioning-esp32/sdkconfig -D IDF_TARGET=esp32 build
clang++ -std=c++17 -Wall -Wextra -Werror -fsyntax-only -Icomponents/ble/include tools/test_provisioning_protocol.cpp
```

The last command executes compiler static assertions against production protocol
helpers: commands, ACK fields, fragments, limits, UTF-8, duplicates/overlap,
incomplete/mismatched commits, BEGIN replacement, cancellation, and timeout/wraparound.
It does not exercise radio, NVS failures, or scheduling. Builds do not flash hardware.

## Results from this change (2026-10-06)

ESP-IDF 5.5.5 / Xtensa GCC 14.2.0, final source:

| Verification | Result |
| --- | --- |
| ESP32-S3 isolated build | Exit 0; image 0xFC700 bytes; 0x3900 (14,592) bytes free in 1 MiB app partition |
| ESP32 isolated build | Exit 0; image 0xFD950 bytes; 0x26B0 (9,904) bytes free in 1 MiB app partition |
| C++17 protocol assertions, ESP clang 19.1.2, -Wall -Wextra -Werror | Exit 0; all static assertions passed |
| Repository shared UUID tests: python -B -m unittest discover -s tools -p 'test_*.py' | Exit 0; 3 tests passed |
| git diff --check -- firmware docs/ble_wifi_provisioning.md | Exit 0; no whitespace errors |

No compiler warnings were reported for modified sources. Both app partitions have
about 1% free space; future additions need a size check. Git reports LF/CRLF
conversion notices on Windows. The SDK also skips its esp_blockdev directory
because it has no CMakeLists.txt; that did not prevent either build.
No flashing, phone pairing, router association, physical NVS fault injection,
or 1 kHz timing acceptance was performed during these checks. The firmware still
uses FakeADC; this verifies compilation and protocol logic, not physical ADC/OLED
operation. All hardware cases above remain unexecuted.
