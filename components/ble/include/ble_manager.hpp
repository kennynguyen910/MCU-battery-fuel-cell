#pragma once

#include <atomic>
#include <cstdint>
#include "latest_frame_store.hpp"
#include "diagnostics.hpp"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"

class BLEManager {
public:
    using WifiStatus = bool (*)(void*);
    BLEManager(LatestFrameStore& latest, Diagnostics& diagnostics,
               WifiStatus wifi_status, void* wifi_context)
        : latest_(latest), diagnostics_(diagnostics), wifi_status_(wifi_status),
          wifi_context_(wifi_context) {}
    BLEManager(const BLEManager&) = delete;
    BLEManager& operator=(const BLEManager&) = delete;
    bool init();
    bool start();
    bool isConnected() const { return connected_.load(); }
    void setAcquisitionRunning(bool running) { acquisition_running_.store(running); }

    // NimBLE callbacks use the firmware-lifetime instance assigned at init().
    static int access(uint16_t conn, uint16_t handle, ble_gatt_access_ctxt* ctxt, void* arg);
    static int gapEvent(ble_gap_event* event, void* arg);
    static void onSync();
    static void onReset(int reason);
    static void hostTask(void* arg);
    static void updateTask(void* arg);
private:
    void advertise();
    void update();
    void encodeVoltage(const SampleFrame& frame, std::uint8_t out[80]) const;
    void encodeStatus(std::uint8_t out[8]) const;
    LatestFrameStore& latest_;
    Diagnostics& diagnostics_;
    WifiStatus wifi_status_;
    void* wifi_context_;
    std::atomic<bool> connected_{false};
    std::atomic<bool> acquisition_running_{false};
    std::atomic<bool> voltage_subscribed_{false};
    std::atomic<bool> status_subscribed_{false};
    std::atomic<std::uint16_t> connection_{0xffff};
    std::uint16_t voltage_handle_ = 0;
    std::uint16_t status_handle_ = 0;
    std::uint8_t config_value_ = 0;
    std::uint8_t read_voltage_[80]{};
    bool have_read_voltage_ = false;
    std::uint8_t address_type_ = 0;
    bool initialized_ = false;
    bool started_ = false;
    static constexpr std::uint32_t STACK_BYTES = 4096;
    StackType_t stack_[STACK_BYTES / sizeof(StackType_t)]{};
    StaticTask_t task_control_{};
    static BLEManager* instance_;
};
