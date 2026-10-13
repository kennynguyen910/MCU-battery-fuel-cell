# Production Android UDP collection

ESP32 -> Wi-Fi/UDP -> Flutter Android App -> local capture journal -> HTTP API -> PostgreSQL -> Website

The existing measurement-v1 format, 10-frame batches, 20 ms partial-batch timeout,
1 kHz acquisition timer, queue, and measurement BLE UUIDs remain unchanged.
FakeADC is simulated; REAL still fails compilation until a hardware driver exists.

## Configuration extension

The separate provisioning service keeps its v1 Control/Data/Status UUIDs and
BEGIN/COMMIT/CANCEL, encrypted authenticated links, 13-byte fragments and 60 s expiry.
Data object type 4 carries `[ssidLength, passwordLength, ssid UTF-8, password UTF-8,
collectorIPv4(4 bytes), collectorPort(2 bytes big endian)]`, max 103 bytes.
Type 1 remains the legacy credential object and configures no UDP destination.
Mixed types inside one transaction are rejected. Old firmware rejects type 4;
update both app and firmware. No laptop-IP fallback is provided.

wifi_cfg persists collector as a six-byte NVS blob alongside SSID/password.
SSID invalidation precedes updates, so interrupted writes do not revive mixed
old/new credentials. The collector snapshot is published only after successful
credential persistence and restored on boot. No NVS reads occur in acquisition
or the network consumer. Forget removes credentials and collector configuration.

## Operation

Sign into the Android app with a phone-reachable API URL. Open Direct Android
Wi-Fi / UDP collector. It binds 5005 by default; to change port, disconnect first,
edit the port, then start the receiver. Scan/connect BLE for Wi-Fi setup. Enter
SSID/password and verify the suggested phone LAN IPv4. The port shown is the
active receiver port. Submit and complete OS pairing. The app retries discovery
while Android reports bonding; Refresh can retry failed discovery.

Use the same reachable LAN; AP client isolation prevents reception. The receiver
pins the BLE-reported ESP32 IP, or the first valid packet sender when no status is
available. Other senders are ignored. A BLE-reported ESP32 IP change stops capture and
requires a new session. To change device/source, disconnect and
create a new session. Create session and Start capture once valid packets arrive.
Keep the collector screen open and the app in the foreground: no background
service is introduced. BLE can disconnect without stopping Wi-Fi capture.
Reprovision if phone DHCP address changes; a DHCP reservation is useful.

Raw UDP has CRC integrity but no sender authentication or acknowledgements.
Bounded buffers and sequence metrics report losses; a full journal stops accepting
new capture data until saved uploads can progress. Not every acquired frame is
guaranteed delivered. Local UTC is anchored to the last device frame in a batch;
monotonic device intervals survive jitter/retry. Source/status/raw device time stay
in the local journal; the unchanged database schema stores timestamped voltages.

Normal start-app.js disables both backend UDP reception and synthetic generation.
Direct server.js enables a bench relay only with BENCH_DEVICE_UDP_ENABLED=1; old
DEVICE_UDP_ENABLED and DEVICE_IP do not implicitly enable it. Browser relay/tests
are retained, separate from production Android, and do not prove hardware delivery.

## Independent boundary verification

1. **Receiver/decoder:** run `flutter test --no-pub test/native_udp_test.dart`.
   Actual loopback UDP validates parsing, signed channels, CRC rejection and local
   journal-before-HTTP ordering. Fixture data is explicitly simulated.
2. **BLE configuration:** bind phone receiver first; complete pairing; discover
   5ecf1000 and all three characteristics; verify fields enable. Provision SSID,
   password, phone IPv4/port. Confirm credential acknowledgement before Wi-Fi
   Connected status. No password should appear in logs. Interrupt a transaction:
   no partial configuration should apply; staging expires after 60 seconds.
3. **ESP32 -> phone:** stop any laptop UDP listener. Enable FakeADC for this test,
   check serial log shows configured phone destination and simulated ADC source.
   Phone datagram/frame counters must rise near 100 datagrams/1000 frames per sec.
   Verify all 16 values, sequence metrics and simulated badge. Disconnect BLE:
   UDP continues. Power-cycle ESP32: destination and Wi-Fi credentials persist.
4. **Phone -> journal:** create/start a session, take API offline, leave UDP running
   for a bounded interval. Saved pending grows; packets continue independently.
   Stop capture and return cleanly so queued frames drain. Restart the app:
   journal entries/timestamps remain pending. Do not force-close before queue drain.
5. **Journal -> API:** restore API and sign into the same account/address. Pending
   entries upload through POST /api/sessions/{id}/measurements, with unchanged
   recordedAt/channels. /health must report storage=postgres and deviceReceiver=false.
   Confirm no production GET /api/device-frames requests and no backend UDP socket.
6. **API -> PostgreSQL:** inspect measurement rows joined to test_session/device;
   each saved frame has channels 0..15, UTC timestamp, voltage and session UUID.
   Retry the same upload: unique timestamp/channel keys do not duplicate rows.
7. **Database -> website:** open web history, select that session, filter UTC range
   and channel. Verify displayed values/times against SQL. Stop/disconnect phone
   and ESP32: website still reads saved history through GET /api/sessions/{id}.
8. **Acquisition:** compare timer/queue/network diagnostics under API outage,
   UDP loss and BLE disconnect. Acquisition stays at its existing 1 kHz schedule;
   BLE latest-frame notifications are not used for the Wi-Fi stream. Actual
   hardware throughput and Android long-run acceptance must be measured physically.
