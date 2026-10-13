import 'device_packets.dart';

/// Sequence metrics apply to observed frames, not screen refreshes.
/// A low sequence plus a regressed device clock estimates reboot; without a
/// boot identifier it cannot reliably distinguish every reboot from delayed data.
class ReceiverIntegrity {
  int received = 0, missing = 0, duplicates = 0, outOfOrder = 0;
  int restarts = 0, invalidTimestamps = 0;
  int? lastSequence, lastTimestampUs;

  bool accept(DeviceSample frame) {
    received++;
    final previous = lastSequence;
    if (previous != null) {
      final delta = (frame.sequence - previous) & 0xffffffff;
      final reboot = frame.sequence <= 10 &&
          previous < 0xfffffff0 &&
          delta >= 0x80000000 &&
          frame.timestampUs < lastTimestampUs!;
      if (reboot) {
        restarts++;
      } else if (delta == 0) {
        duplicates++;
        return false;
      } else if (delta >= 0x80000000) {
        outOfOrder++;
        return false;
      } else if (frame.timestampUs <= lastTimestampUs!) {
        invalidTimestamps++;
        return false;
      } else {
        missing += delta - 1;
      }
    }
    lastSequence = frame.sequence;
    lastTimestampUs = frame.timestampUs;
    return true;
  }

  void resetBaseline() {
    lastSequence = null;
    lastTimestampUs = null;
  }
}
