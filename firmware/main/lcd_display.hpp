#pragma once
#include <atomic>
#include "latest_frame_store.hpp"
#include "wifi_manager.hpp"
class BLEManager;

// Firmware-lifetime inputs. BLE is bound atomically after its existing constructor.
// All connection states are read from their managers, never copied into globals.
struct LcdDisplayInputs {
    LatestFrameStore& latest;
    WiFiManager& wifi;
    const bool source_enabled;
    std::atomic<const BLEManager*> ble{nullptr};
};
void startLcdDisplay(LcdDisplayInputs& inputs);
