#include "lcd_display_format.hpp"
using namespace lcd_display;

namespace {
bool equal(const char* a, const char* b)
{
    for (unsigned i = 0; ; ++i) {
        if (a[i] != b[i]) return false;
        if (!a[i]) return true;
    }
}
bool prefix(const char* a, const char* b)
{
    while (*b) if (*a++ != *b++) return false;
    return true;
}
int check()
{
    Snapshot s;
    Rows r;
    formatPage(0, s, r);
    if (!prefix(r.text[0], "CH01: NO DATA") || !prefix(r.text[1], "CH02: NO DATA")) return 1;
    formatPage(9, s, r);
    if (!prefix(r.text[0], "ADC: DISABLED")) return 2;
    s.sourceEnabled = true;
    formatPage(9, s, r);
    if (!prefix(r.text[0], "ADC: NO DATA")) return 3;
    s.hasFrame = true;
    s.timestampUs = 1000000;
    s.nowUs = 1001000;
    s.simulated = true;
    s.microvolts[0] = 1230000;
    s.microvolts[1] = -1250000;
    formatPage(0, s, r);
    if (!equal(r.text[0], "CH01: +1.230 V S") || !equal(r.text[1], "CH02: -1.250 V S")) return 4;
    formatPage(9, s, r);
    if (!prefix(r.text[0], "ADC: SIMULATED") || !prefix(r.text[1], "DATA: FRESH")) return 5;
    const int32_t values[] = {5000000, -5000000, 0, -1, 1230499, 1230500, -1230500};
    const char* expected[] = {"+5.000", "-5.000", "+0.000", "-0.000", "+1.230", "+1.231", "-1.231"};
    for (unsigned i = 0; i < 7; ++i) {
        s.microvolts[0] = values[i];
        formatPage(0, s, r);
        if (!prefix(r.text[0] + 6, expected[i])) return 6;
    }
    s.microvolts[0] = static_cast<int32_t>(-2147483647 - 1);
    formatPage(0, s, r);
    if (!prefix(r.text[0] + 6, "INVALID")) return 7;
    s.microvolts[0] = 5000001;
    formatPage(0, s, r);
    if (!prefix(r.text[0] + 6, "INVALID")) return 8;
    s.nowUs = s.timestampUs + STALE_US;
    if (dataState(s) != Data::Fresh) return 9;
    ++s.nowUs;
    formatPage(0, s, r);
    if (!prefix(r.text[0] + 6, "STALE")) return 10;
    s.timestampUs = s.nowUs + 1;
    if (dataState(s) != Data::Invalid) return 11;
    s.timestampUs = 0;
    if (dataState(s) != Data::Invalid) return 12;
    s.timestampUs = s.nowUs;
    for (unsigned page = 0; page < 8; ++page) {
        formatPage(page, s, r);
        for (unsigned row = 0; row < 2; ++row) {
            const unsigned channel = page * 2 + row + 1;
            if (r.text[row][2] != static_cast<char>('0' + channel / 10) || r.text[row][3] != static_cast<char>('0' + channel % 10)) return 13;
        }
    }
    for (unsigned page = 0; page < PAGE_COUNT; ++page) {
        formatPage(page, s, r);
        for (const auto& row : r.text) {
            for (unsigned i = 0; i < 16; ++i) if (!row[i]) return 14;
            if (row[16] != 0) return 15;
        }
        if (pageForElapsed(page * 2500000ULL, 2500000) != (page + 9) % 10) return 16;
    }
    if (pageForElapsed(2499999, 2500000) != 9 ||
        pageForElapsed(2500000, 2500000) != 0 ||
        pageForElapsed(25000000, 2500000) != 9 ||
        pageForElapsed(250000, 2500000) != 9 ||
        pageForElapsed(123, 0) != 9) return 17;
    const Wifi wifi[] = {Wifi::Unprovisioned, Wifi::Connecting, Wifi::Connected, Wifi::Failed, Wifi::Unknown};
    const char* labels[] = {"WIFI: UNPROV", "WIFI: CONNECTING", "WIFI: CONNECTED", "WIFI: FAILED", "WIFI: UNKNOWN"};
    for (unsigned i = 0; i < 5; ++i) {
        s.wifi = wifi[i];
        formatPage(8, s, r);
        if (!prefix(r.text[0], labels[i])) return 18;
    }
    s.ble = Ble::Disconnected;
    formatPage(8, s, r);
    if (!equal(r.text[1], "BLE:DISCONNECTED")) return 19;
    s.ble = Ble::Connected;
    formatPage(8, s, r);
    if (!prefix(r.text[1], "BLE: CONNECTED")) return 20;
    s.ble = Ble::Unknown;
    formatPage(8, s, r);
    if (!prefix(r.text[1], "BLE: UNKNOWN")) return 21;
    s.simulated = false;
    s.microvolts[0] = 0;
    formatPage(0, s, r);
    if (r.text[0][15] != ' ' || !prefix(r.text[0] + 6, "+0.000")) return 22;
    formatPage(9, s, r);
    if (!prefix(r.text[0], "ADC: UNKNOWN")) return 23;
    return 0;
}
}
int main() { return check(); }
