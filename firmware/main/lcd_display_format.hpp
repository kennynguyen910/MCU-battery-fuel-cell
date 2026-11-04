#pragma once
#include <stdint.h>

namespace lcd_display {
constexpr unsigned PAGE_COUNT = 10;
constexpr uint64_t STALE_US = 500000; // 500 periods of the current 1 kHz acquisition.
enum class Wifi { Unknown, Unprovisioned, Connecting, Connected, Failed };
enum class Ble { Unknown, Disconnected, Connected };
enum class Data { Disabled, Missing, Invalid, Stale, Fresh };

// Ephemeral presentation input, projected from one protected SampleFrame copy.
// No measurement ownership, publication or queues live in the formatter.
struct Snapshot {
    bool sourceEnabled = false;
    bool hasFrame = false;
    bool simulated = false;
    uint64_t timestampUs = 0;
    uint64_t nowUs = 0;
    int32_t microvolts[16]{};
    Wifi wifi = Wifi::Unknown;
    Ble ble = Ble::Unknown;
};
struct Rows { char text[2][17]; };

Data dataState(const Snapshot& snapshot);
unsigned pageForElapsed(uint64_t elapsedUs, uint64_t pageUs);
const char* wifiText(Wifi wifi);
const char* bleText(Ble ble);
void formatPage(unsigned page, const Snapshot& snapshot, Rows& rows);
} // namespace lcd_display
