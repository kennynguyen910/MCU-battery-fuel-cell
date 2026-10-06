# BLE Wi-Fi status and scanning (protocol version 1)

Path convention: ESP-IDF commands and firmware paths (main/, components/, tools/, sdkconfig) are relative to firmware/. Shared compatibility tools run from the repository root.

Implemented: status READ/NOTIFY, GET_STATUS, asynchronous START_SCAN, fragmented
scan results, and BLE credential staging/save/apply/clear. Credential operations
require link encryption by default. No phone-app, pairing/passkey UI, SoftAP,
provisioning framework, or new measurement formats are included.

## GATT layout

Connect to `BatteryMonitor`. The original `5ecf0000` service and its four
characteristics/measurement formats remain unchanged. Advertising still contains
the original service UUID (now marked an incomplete list); discover the new
service after connecting. UUID suffix for every row below is
`-41c2-4cc4-9c96-640f406021d0`.

| Attribute | UUID prefix | Properties |
| --- | --- | --- |
| Wi-Fi Provisioning service | `5ecf1000` | Primary |
| Control | `5ecf1001` | Write, Notify |
| Data | `5ecf1002` | Write, Notify |
| Wi-Fi Status | `5ecf1003` | Read, Notify |

Subscribe to Control before sending commands. A valid command without Control
subscription is rejected with an ATT error. Subscribe to Status for GET_STATUS
notifications and Data for scan results. Data WRITE accepts only the bounded
WIFI_CREDENTIALS format described below. Use ATT Write Request for these writes.

## Wi-Fi Status: exactly 8 bytes

| Byte | Meaning |
| --- | --- |
| 0 | Version `01` |
| 1 | WiFiManager state: `00` unprovisioned, `01` connecting, `02` connected, `03` connection failed |
| 2 | Flags: bit 0 valid credentials stored, bit 1 scan pending/running, bit 2 receiving/applying credentials (also set during clear), bit 3 actual BLE encryption state; bits 4-7 zero |
| 3 | Last provisioning error; an accepted command resets it to OK |
| 4-7 | IPv4 octets in network order, all zero without a current connection |

Status queries use cached atomic WiFiManager fields, never NVS reads in GATT.
The stored-credentials cache is updated by boot/load, save, and clear paths.
Example connected to 192.168.1.42, credentials stored, unencrypted, no scan:
`01 02 01 00 C0 A8 01 2A`.

Notifications occur for GET_STATUS, scan transitions, credential transaction
transitions, and WiFiManager connection-state changes. WiFiManager has a narrow
firmware-lifetime listener that posts snapshots into an eight-entry static queue;
the NimBLE host drains it without polling or sending BLE from Wi-Fi callbacks.
Brief CONNECTION_FAILED -> CONNECTING retry transitions are preserved. If the
queue fills, intermediate snapshots may be dropped and current status is resynced.
State-change packets describe the transition snapshot; READ always queries current
state. The IP cache is cleared on disconnect. Notification acceptance does not
confirm phone delivery; READ/GET_STATUS remain available for synchronization.

## Control messages

Requests: `[version, opcode, transaction, payload_length, payload...]`.
Commands are GET_STATUS `01`, START_SCAN `02`, BEGIN_CREDENTIALS `03`,
COMMIT_CREDENTIALS `04`, CLEAR_CREDENTIALS `05`, and CANCEL `06`, each exactly
four bytes with zero payload. Client transactions must be `01` through `FF`; `00` is reserved.

| Response | Bytes |
| --- | --- |
| ACK | `01 80 TT 02 original_opcode 00` |
| ERROR | `01 81 TT 02 original_opcode error` |
| SCAN_COMPLETE | `01 82 TT 01 fully_reported_network_count` |

Malformed requests receive ERROR when Control is subscribed. For a short request,
missing opcode/transaction bytes are returned as zero; present bytes are echoed.
No received data beyond a four-byte prefix is copied or parsed.

| Error | Meaning |
| --- | --- |
| `00` | OK |
| `01` | Unsupported version |
| `02` | Invalid/unsupported command |
| `03` | Invalid length/payload or transaction zero |
| `04` | Operation busy (scan transaction or station connection attempt in progress) |
| `05` | Credential operation requires an encrypted BLE link |
| `06` | Wi-Fi scan failed |
| `07` | Invalid SSID |
| `08` | Invalid password or logical credential-object format |
| `09` | NVS save/clear failed |
| `0A` | Wi-Fi apply/connection failed |
| `0B` | Credential transaction timed out |
| `0C` | No staged credentials / object incomplete |
| `0D` | Transaction mismatch |
| `0E` | Fragment/header/bounds/conflicting-overlap error |
| `0F` | Internal error, unavailable worker, or notification failure |

GET_STATUS ACKs, then notifies Status if subscribed. START_SCAN ACKs before
waking a priority-2 communications worker. The ACK confirms the request was
accepted, not that the radio scan has succeeded. A driver-level busy/failure can
therefore produce an ACK followed by ERROR. Scan failure terminates with ERROR;
successful scanning terminates with SCAN_COMPLETE, even if notification failure
requires an ERROR first. No unbounded notification retry occurs.

## Scanning and results

WiFiManager starts `esp_wifi_scan_start(..., false)` and its worker sleeps on a
SCAN_DONE semaphore, bounded to 15 seconds. After a scan timeout, further scans
fail until Wi-Fi reinitialization/reboot; this prevents a delayed completion event
from being mistaken for a new scan. No scan or NVS work runs in GATT or
acquisition. An unprovisioned device starts the station radio for explicit scans
but makes no connection attempts. Scanning does not save/change credentials or
intentionally disconnect Wi-Fi. A station currently connecting reports BUSY;
retry after connection settles, or test on an unprovisioned device. Reconnect is
deferred if a disconnect occurs during scanning, then resumed after scan cleanup.

The driver returns strongest RSSI first. At most the strongest 15 AP records are
retrieved; empty/invalid SSIDs are skipped and duplicate SSIDs keep their first
(strongest) instance. The count can be less than 15 because filtering occurs
after the candidate cap. Driver scan-list memory is released after completion.

Each logical result is `[index, signed_int8_RSSI, auth, SSID_length, SSID_bytes...]`.
SSID length is 1-32 bytes, with no transmitted null terminator. Auth codes:
`00` Open, `01` WEP, `02` WPA Personal, `03` WPA2 Personal, `04` WPA/WPA2,
`05` WPA3 Personal, `06` WPA2/WPA3, `07` Enterprise, `FF` unknown. Unsupported
modes (including OWE/WAPI/DPP) use unknown without failing the scan.

Each Data notification contains:
`[01, 02, transaction, object_id, offset, total_object_length, chunk_length, chunk...]`.
Object ID equals the zero-based result index. A conservative 13-byte chunk limit
keeps every notification at or below 20 bytes, even with ATT MTU 23. Larger MTUs
use the same format/chunk size. A maximum-length SSID makes a 36-byte object,
sent as chunks of 13, 13, and 10 bytes at offsets 0, 13, and 26.

Notifications are paced one fragment per 20 ms using a NimBLE host callout. The
scan worker transfers results to the host by an event; only the host sends BLE
responses. Busy remains set through result delivery to protect the fixed buffer.
SCAN_COMPLETE counts only objects whose entire set of fragments was accepted by
NimBLE; this is not confirmed phone delivery. On a failed fragment, remaining
results are abandoned, ERROR is attempted, then SCAN_COMPLETE reports the count
of completed objects. Discard incomplete objects client-side.

Without Data subscription, a scan can finish internally; if results exist,
ERROR INTERNAL_ERROR and SCAN_COMPLETE count 0 are attempted. With no APs, count
0 is a normal success. Disconnect clears subscriptions, stops fragment delivery,
and invalidates the session. A scan already running finishes and releases its
resources, but its results are discarded rather than sent to a new connection.
A new client may see BUSY until that scan finishes.

## nRF Connect hardware test

1. In an ESP-IDF terminal run `idf.py build`, then
   `idf.py -p COM3 flash monitor` (substitute your serial port). Keep saved
   credentials intact and development seeding disabled; do not erase flash.
2. In nRF Connect scan/connect to BatteryMonitor. Discover services; refresh the
   phone's GATT cache if necessary. Check both service UUIDs and all seven custom
   characteristics. Enable Control, Data, and Wi-Fi Status notifications.
3. Read Wi-Fi Status: exactly eight bytes. Confirm state/flags/IP against serial
   logs. Repeat on an unprovisioned device without adding credential writes here.
4. Write **hex bytes**, with Write Request, to Control: `01 01 01 00`.
   Expect `01 80 01 02 01 00` and an eight-byte Status notification.
5. Write `01 02 02 00`. Expect `01 80 02 02 02 00`, Data fragments with transaction
   `02`, and finally `01 82 02 01 NN`. Reassemble each object by ID and offset;
   confirm plausible SSIDs/RSSI. Keep default MTU 23 for this fragmentation test.
6. Quickly send `01 02 03 00` during the previous scan/delivery. Expect
   `01 81 03 02 02 04` (BUSY). After completion, repeat a scan successfully.
7. Send `02 01 04 00` (bad version): expect `01 81 04 02 01 01`.
   Send `01 02 05 01` (bad payload length): expect `01 81 05 02 02 03`.
   Send `01 07 06 00` (unsupported command): expect `01 81 06 02 07 02`.
   Send `01 01 00 00` (reserved transaction): expect error `03`. Also test a
   one-byte write; no reboot or out-of-bounds access should occur.
8. Unsubscribe Data and scan: expect graceful count 0/error behavior. Disconnect
   during a scan, reconnect, resubscribe, and scan again after BUSY clears. Old
   transaction fragments must not appear on the new link.
9. Run `python .\tools\udp_receiver.py` while connected to Wi-Fi. Monitor serial
   diagnostics while scanning repeatedly: acquisition near 1000 frames/s, no
   sustained degradation, zero dropped frames/queue overflow/ADC errors. Scanning
   shares radio airtime and may transiently affect UDP delivery; record actual
   receiver gaps and recovery rather than treating a build as timing proof.
10. Read existing Voltage Data and System Status. Request MTU 128 (at least 83)
    and subscribe to Voltage Data: the original 80-byte notifications should
    continue near 10 Hz alongside provisioning. Repeat on ESP32-S3 later.

Compile-time parser/fragment tests live in `tools/test_provisioning_protocol.cpp`.
They cover all six commands/all valid transaction IDs, short/oversized inputs,
unsupported version/command, reserved transaction, payload mismatch, exact scan
fragment reconstruction, and credential reassembly/validation/cleanup cases. Hardware persistence,
radio coexistence, stack headroom, and sustained timing still require board tests.


## Credential transactions and security

The provisioning states are IDLE, SCANNING, RECEIVING_CREDENTIALS, and
APPLYING_CREDENTIALS. Scan delivery owns SCANNING until SCAN_COMPLETE. Receiving
or applying credentials blocks new scans and other incompatible operations with
BUSY. GET_STATUS remains available. CLEAR uses APPLYING_CREDENTIALS too.

A single authorization helper gates BEGIN, credential Data, COMMIT, and CLEAR.
By default the existing NimBLE link must be encrypted; otherwise ERROR `05` is
returned without accepting or applying credentials. Pair/bond through nRF Connect
if supported by the phone/stack, then read Status to verify flag bit 3 (`08`).
No new pairing UI, passkey policy, bonding configuration, or measurement-service
security requirements were added. Encryption alone does not establish an
application-level authorized owner or guarantee authenticated/MITM-resistant
pairing; final pairing/authorization UX remains future work.

For explicit development testing only, set
`BATTERY_MONITOR_ALLOW_INSECURE_PROVISIONING_DEV` to `1` in
`components/ble/include/provisioning_config.hpp` and rebuild/flash. This defaults
to `0` and logs a prominent warning once at startup when enabled. It MUST be
returned to `0` for final firmware. The status encryption flag still reports the
actual link state even with the bypass enabled. CANCEL is permitted without
current encryption because it can only discard the current link's RAM staging.

BEGIN `01 03 TT 00` starts a credential transaction and ACKs. It does not touch
NVS or the current Wi-Fi connection. Only one transaction is active. A rolling
60-second inactivity timeout starts at BEGIN and restarts on each accepted
fragment, including identical duplicates. Complete but uncommitted objects also
expire. Timeout clears staging and sends ERROR `0B` for BEGIN if still connected.

## Incoming credential object and fragmentation

Data writes have the existing seven-byte header:
`[01, 01, transaction, 00, offset, total_length, chunk_length, chunk...]`.
Message type `01` is WIFI_CREDENTIALS; object ID must be zero. SCAN_RESULT stays
`02`. A logical object is `[SSID_length, password_length, SSID_bytes, password_bytes]`.
Total length must exactly equal `2 + SSID_length + password_length`, at most 97.

SSID must be 1-32 bytes. Password must be empty for an open network or 8-63 bytes
for a WPA passphrase, matching the existing WiFiManager validation. Nonempty
passwords shorter than eight bytes and embedded NUL bytes are rejected rather
than silently truncated by the existing NVS string API. The BLE format does not
accept the existing storage API's optional 64-hex raw PSK. Counts are byte lengths,
not Unicode character counts; no terminators are transmitted.

A fixed 97-byte reassembly buffer and 13-byte received bitmap support explicit,
out-of-order offsets. Identical duplicate/overlapping bytes are accepted without
incrementing the received count twice. Conflicting overlaps reject the entire
fragment before changing staging. Every required byte must be present before
COMMIT. Parsed output uses 33-byte SSID and 64-byte password buffers, terminated
locally. Total length must remain constant throughout a transaction, chunk length
must be nonzero, and the actual write must exactly contain the declared chunk.
At MTU 23 send at most 13 object bytes per Data write; larger negotiated MTUs may
carry larger chunks within the same bounded object limit.

Accepted fragments receive the normal ATT Write Response, not a separate Control
ACK. Data errors are Control ERROR messages using original opcode BEGIN (`03`)
and the incoming transaction ID. Invalid framing/mismatched transactions preserve
existing staging for retry; a fully reassembled invalid object is securely erased
and ends the transaction. Start again with BEGIN after that error.

## Commit, clear, cancel, and disconnect

COMMIT `01 04 TT 00` requires the matching transaction and a complete valid object.
It ACKs acceptance, moves to APPLYING_CREDENTIALS, transfers a bounded copy to the
existing scan/provisioning worker, and wipes host staging. The worker calls
`WiFiManager::saveCredentials()`, wipes its input copy, and on success calls
`applyStoredCredentials()`. That method reloads NVS, restarts station operation,
and initiates connection without waiting for DHCP. No NVS access occurs in the
BLE implementation. WiFiManager remains the source of truth for CONNECTING,
CONNECTED, CONNECTION_FAILED, and normal retries. Accepted work is not rolled
back if BLE disconnects after COMMIT: it finishes and wipes the worker copy, while
transaction responses for the old BLE session are discarded. Provisioning returns
to IDLE after save/apply returns; it does not remain busy until DHCP finishes.

The existing `wifi_cfg` namespace and `ssid`/`password` keys are unchanged. BEGIN,
fragments, CANCEL, timeout, and pre-COMMIT disconnect leave saved credentials
untouched. NVS writes are not an atomic multi-key replacement: the existing API
invalidates SSID before writing the new password/SSID. A failed or interrupted
COMMIT can therefore leave credentials absent/partial; old credentials are not
guaranteed to survive. A save failure reports `09` and does not intentionally
reconfigure the currently running Wi-Fi link. Retry provisioning to recover.
Wrong passwords that save successfully remain stored and cause the existing
connection-failure/retry behavior until replaced or cleared.

CLEAR `01 05 TT 00` is accepted only when IDLE. After ACK, the same worker calls
`clearCredentials()`, stopping Wi-Fi and erasing only the two credential keys,
then `applyStoredCredentials()` to restart the unprovisioned scan-capable radio.
Runtime reload explicitly disables development seeding and reuses initialized
NVS; CLEAR does not erase the full partition. Leave `WIFI_ENABLE_DEVELOPMENT_SEED`
at `0`, or a later reboot can still reseed the development credentials. NVS
failure reports `09`; radio restart failure reports `0F`. A partial clear may
leave incomplete credentials, and the cached stored flag is cleared conservatively.

CANCEL `01 06 TT 00` requires the matching receiving transaction. It ACKs, stops
the timeout, securely wipes staging, and returns to IDLE without modifying Wi-Fi
or NVS. A receiving transaction (complete or incomplete) is also discarded on BLE
disconnect/reset. CANCEL cannot undo a worker operation already accepted by COMMIT
or CLEAR; those return BUSY. Disconnect never waits for the worker.

`secureZero()` uses volatile byte writes. Scoped guards erase credential-bearing
local buffers on every return path; staging and worker copies are wiped explicitly.
No password or raw credential fragment is logged. NimBLE-owned incoming buffers
and the Wi-Fi/NVS driver's necessary internal copies follow their own lifetimes;
the helper does not claim to erase framework-owned memory or persistent storage.

## nRF Connect credential test (fake example)

Use a test network, not a production credential. Disable development seeding.
Build/flash, connect to BatteryMonitor, and enable Control and Wi-Fi Status
notifications. Establish encryption (verify status flag `08`), or explicitly use
the development-only bypass described above. With bypass off and an unencrypted
link, BEGIN must return `01 81 10 02 03 05` and leave Wi-Fi unchanged.

1. BEGIN: write hex `01 03 10 00` to Control. Expect `01 80 10 02 03 00`.
   Current Wi-Fi must stay connected; status transaction flag bit 2 becomes set.
2. Fake credentials: SSID `TestWiFi` (8 bytes), password `example123` (10 bytes).
   The logical object is 20 bytes (`14` hex):
   `08 0A 54 65 73 74 57 69 46 69 65 78 61 6D 70 6C 65 31 32 33`.
   Write these two hex packets to **Data**, using Write Request:

   ```text
   01 01 10 00 00 14 0D 08 0A 54 65 73 74 57 69 46 69 65 78 61
   01 01 10 00 0D 14 07 6D 70 6C 65 31 32 33
   ```

   They also work in reverse order. Repeating an identical packet is harmless.
   Substitute your own test bytes and recalculate lengths for a real test AP.
3. COMMIT: write `01 04 10 00` to Control. Expect `01 80 10 02 04 00`, then
   status CONNECTING and eventually CONNECTED or CONNECTION_FAILED. The fake
   example connects only if such an AP actually exists with that password.
4. After successfully provisioning your test AP, power-cycle without erasing
   flash. Expect saved credentials to reload and connect without BLE provisioning.
5. Repeat BEGIN/Data/COMMIT using a syntactically valid but wrong password.
   Expect CONNECTION_FAILED (`03`, error `0A`) and normal reconnect attempts;
   acquisition and BLE must remain usable. Provision a correct replacement.
6. CANCEL: BEGIN `01 03 11 00`, send the first example fragment with transaction
   changed from `10` to `11`, then Control `01 06 11 00`. Expect
   `01 80 11 02 06 00`; a later COMMIT for `11` returns `0C`. Saved Wi-Fi stays.
7. Begin/send a partial object, disconnect BLE, reconnect/resubscribe, and attempt
   its COMMIT. Expect `0C`, no crash, and unchanged saved Wi-Fi. Also test a partial
   transaction left idle for over 60 seconds: expect timeout `0B` and cleared flag.
8. CLEAR: while idle write `01 05 12 00`. Expect `01 80 12 02 05 00`, then
   UNPROVISIONED with stored flag/IP cleared. BLE stays available; verify START_SCAN
   still works. Reboot with seeding disabled and verify credentials remain absent.
9. During all tests monitor serial diagnostics: aim for about 1000 frames/s,
   no drops/queue overflow/ADC errors/consumer sequence gaps. NVS flash writes can
   temporarily stall code execution on ESP32, so measure late/missed timing and
   sustained rate as well; a successful build cannot establish these timings.
10. Repeat GET_STATUS/START_SCAN and existing Voltage Data notifications (MTU at
    least 83), and run the UDP receiver after Wi-Fi connects. During deliberate
    Wi-Fi replacement/clear, unsent UDP frames are expected; the acquisition and
    serialization paths remain unchanged.

Protocol tests additionally cover single/multiple/out-of-order credential fragments,
32-byte SSID, 63-byte password, open network, empty/NUL SSID, malformed object and
chunk lengths, boundary overflow, mismatched transaction, incomplete commit,
duplicates/conflicts, cancel zeroing, and timeout/wraparound zeroing. No credential
formatter exists. Re-run these hardware tests and security checks on ESP32-S3.
