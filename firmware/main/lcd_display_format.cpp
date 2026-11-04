#include "lcd_display_format.hpp"

namespace lcd_display {
namespace {
void put(char* row, const char* text, unsigned at = 0)
{
    while (at < 16 && *text) row[at++] = *text++;
}
void voltage(char* row, unsigned channel, const Snapshot& s, Data state)
{
    put(row, "CH");
    row[2] = '0' + (channel + 1) / 10;
    row[3] = '0' + (channel + 1) % 10;
    row[4] = ':';
    if (s.hasFrame && s.simulated) row[15] = 'S';
    if (state != Data::Fresh) {
        put(row, state == Data::Stale ? "STALE" :
                 state == Data::Invalid ? "INVALID" : "NO DATA", 6);
        return;
    }
    const int64_t uv = s.microvolts[channel];
    const uint64_t magnitude = uv < 0 ? static_cast<uint64_t>(-uv) : uv;
    if (magnitude > 5000000) {
        put(row, "INVALID", 6);
        return;
    }
    const unsigned mv = static_cast<unsigned>((magnitude + 500) / 1000);
    row[6] = uv < 0 ? '-' : '+';
    row[7] = '0' + mv / 1000;
    row[8] = '.';
    row[9] = '0' + (mv / 100) % 10;
    row[10] = '0' + (mv / 10) % 10;
    row[11] = '0' + mv % 10;
    row[13] = 'V';
}
}
Data dataState(const Snapshot& s)
{
    if (!s.sourceEnabled) return Data::Disabled;
    if (!s.hasFrame) return Data::Missing;
    if (!s.timestampUs || s.timestampUs > s.nowUs) return Data::Invalid;
    return s.nowUs - s.timestampUs > STALE_US ? Data::Stale : Data::Fresh;
}
unsigned pageForElapsed(uint64_t elapsedUs, uint64_t pageUs)
{
    // Start with provenance/data health before showing voltage pages.
    return pageUs ? static_cast<unsigned>((9 + (elapsedUs / pageUs) % PAGE_COUNT) % PAGE_COUNT) : 9;
}
const char* wifiText(Wifi state)
{
    switch (state) {
    case Wifi::Unprovisioned: return "WIFI: UNPROV";
    case Wifi::Connecting: return "WIFI: CONNECTING";
    case Wifi::Connected: return "WIFI: CONNECTED";
    case Wifi::Failed: return "WIFI: FAILED";
    default: return "WIFI: UNKNOWN";
    }
}
const char* bleText(Ble state)
{
    switch (state) {
    case Ble::Connected: return "BLE: CONNECTED";
    case Ble::Disconnected: return "BLE:DISCONNECTED"; // Exactly 16 characters.
    default: return "BLE: UNKNOWN";
    }
}
void formatPage(unsigned page, const Snapshot& s, Rows& out)
{
    for (auto& row : out.text) {
        for (unsigned i = 0; i < 16; ++i) row[i] = ' ';
        row[16] = '\0';
    }
    const auto state = dataState(s);
    if (page < 8) {
        voltage(out.text[0], page * 2, s, state);
        voltage(out.text[1], page * 2 + 1, s, state);
    } else if (page == 8) {
        put(out.text[0], wifiText(s.wifi));
        put(out.text[1], bleText(s.ble));
    } else if (page == 9) {
        const char* adc = "ADC: UNKNOWN";
        const char* data = "DATA: INVALID";
        switch (state) {
        case Data::Disabled: adc = "ADC: DISABLED"; data = "DATA: NONE"; break;
        case Data::Missing: adc = "ADC: NO DATA"; data = "DATA: WAITING"; break;
        case Data::Stale: adc = "ADC: STALE"; data = "DATA: STALE"; break;
        case Data::Invalid: adc = "ADC: INVALID"; break;
        case Data::Fresh:
            adc = s.simulated ? "ADC: SIMULATED" : "ADC: UNKNOWN";
            data = "DATA: FRESH";
            break;
        }
        put(out.text[0], adc);
        put(out.text[1], data);
    } else {
        put(out.text[0], "PAGE: UNKNOWN");
        put(out.text[1], "DATA: UNKNOWN");
    }
}
} // namespace lcd_display
