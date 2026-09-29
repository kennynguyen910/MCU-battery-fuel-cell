# BLE Wi-Fi status and scanning (protocol version 1)

Implemented: status READ/NOTIFY, GET_STATUS, asynchronous START_SCAN, and
fragmented scan-result notifications. **Credential provisioning is NOT YET
IMPLEMENTED.** No incoming SSID/password, credential transaction, BLE clear,
pairing changes, phone app, or framework provisioning is included.

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
notifications and Data for scan results. Data WRITE is reserved: all incoming
writes are rejected with ATT write-not-permitted, without storing their contents.

## Wi-Fi Status: exactly 8 bytes

| Byte | Meaning |
| --- | --- |
| 0 | Version `01` |
| 1 | WiFiManager state: `00` unprovisioned, `01` connecting, `02` connected, `03` connection failed |
| 2 | Flags: bit 0 valid credentials stored, bit 1 scan pending/running, bit 2 credential transaction (always 0), bit 3 actual BLE encryption state; bits 4-7 zero |
| 3 | Last provisioning error; an accepted command resets it to OK |
| 4-7 | IPv4 octets in network order, all zero without a current connection |

Status queries use cached atomic WiFiManager fields, never NVS reads in GATT.
The stored-credentials cache is updated by boot/load, save, and clear paths.
Example connected to 192.168.1.42, credentials stored, unencrypted, no scan:
`01 02 01 00 C0 A8 01 2A`.

Notifications occur for GET_STATUS and scan start/completion. Automatic Wi-Fi
connection-state-change notifications are not implemented; use READ or GET_STATUS.
No new status polling task is added. After a disconnect the IP cache is cleared.

## Control messages

Requests: `[version, opcode, transaction, payload_length, payload...]`.
Only GET_STATUS `01` and START_SCAN `02` are accepted, both exactly four bytes,
with zero payload. Client transactions must be `01` through `FF`; `00` is reserved.

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
| `06` | Wi-Fi scan failed |
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
   credentials and development seeding unchanged; do not erase flash.
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
   Send `01 03 06 00` (unsupported command): expect `01 81 06 02 03 02`.
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
They cover both commands/all valid transaction IDs, short/oversized inputs,
unsupported version/command, reserved transaction, payload mismatch, and exact
fragment reconstruction for every supported SSID length. Hardware persistence,
radio coexistence, stack headroom, and sustained timing still require board tests.
