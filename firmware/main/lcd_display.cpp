#include "sdkconfig.h"
#include "lcd_display.hpp"
#include "lcd_display_format.hpp"
#include "lcd1602.hpp"
#include "ble_manager.hpp"
#include "board_config.hpp"
#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

namespace {
constexpr const char* TAG = "lcd_display";
constexpr unsigned REFRESH_MS = 250;
constexpr uint64_t PAGE_US = 2500000;
static_assert(pdMS_TO_TICKS(REFRESH_MS) > 0);

lcd_display::Snapshot snapshot(LcdDisplayInputs& inputs)
{
    SampleFrame frame{};
    lcd_display::Snapshot s;
    s.sourceEnabled = inputs.source_enabled;
    s.hasFrame = inputs.latest.read(frame);
    // Capture time AFTER the protected copy: a newly published frame must not
    // appear to come from the future because of display-side read ordering.
    s.nowUs = static_cast<uint64_t>(esp_timer_get_time());
    if (s.hasFrame) {
        s.timestampUs = frame.timestamp_us;
        s.simulated = (frame.status & SAMPLE_STATUS_SIMULATED) != 0;
        for (unsigned i = 0; i < 16; ++i) s.microvolts[i] = frame.channels[i];
    }
    using Wifi = lcd_display::Wifi;
    switch (inputs.wifi.getState()) {
    case WiFiState::UNPROVISIONED: s.wifi = Wifi::Unprovisioned; break;
    case WiFiState::CONNECTING: s.wifi = Wifi::Connecting; break;
    case WiFiState::CONNECTED: s.wifi = Wifi::Connected; break;
    case WiFiState::CONNECTION_FAILED: s.wifi = Wifi::Failed; break;
    default: s.wifi = Wifi::Unknown; break;
    }
    if (const auto* ble = inputs.ble.load()) {
        s.ble = ble->isConnected() ? lcd_display::Ble::Connected : lcd_display::Ble::Disconnected;
    }
    return s;
}

esp_err_t runDisplay(LcdDisplayInputs& inputs, i2c_master_bus_handle_t bus)
{
    Lcd1602 lcd;
    auto error = lcd.initialize(bus);
    if (error != ESP_OK) return error;
    const char startup[2][17] = {"BATTERY MONITOR", "INITIALIZING..."};
    error = lcd.writeRows(startup);
    if (error != ESP_OK) return error;
    ESP_LOGI(TAG, "Cycling display initialized; refresh=250 ms page=2500 ms stale=500 ms");
    vTaskDelay(pdMS_TO_TICKS(2500) + 1);
    const auto cycle_start = esp_timer_get_time();
    auto wake = xTaskGetTickCount();
    for (;;) {
        const auto s = snapshot(inputs);
        const auto elapsed = static_cast<uint64_t>(esp_timer_get_time() - cycle_start);
        lcd_display::Rows rows;
        lcd_display::formatPage(lcd_display::pageForElapsed(elapsed, PAGE_US), s, rows);
        error = lcd.writeRows(rows.text); // Only changed rows reach I2C.
        if (error != ESP_OK) return error;
        xTaskDelayUntil(&wake, pdMS_TO_TICKS(REFRESH_MS));
    }
}

void displayTask(void* context)
{
    auto& inputs = *static_cast<LcdDisplayInputs*>(context);
    const int sda = board::config.DISPLAY_SDA;
    const int scl = board::config.DISPLAY_SCL;
    if (sda < 0 || scl < 0 || sda == scl ||
        !GPIO_IS_VALID_OUTPUT_GPIO(sda) || !GPIO_IS_VALID_OUTPUT_GPIO(scl)) {
        ESP_LOGE(TAG, "Unassigned/invalid display pins SDA=%d SCL=%d; disabled", sda, scl);
        vTaskDelete(nullptr);
        return;
    }
    for (;;) {
        i2c_master_bus_config_t config{};
        config.i2c_port = -1;
        config.sda_io_num = static_cast<gpio_num_t>(sda);
        config.scl_io_num = static_cast<gpio_num_t>(scl);
        config.clk_source = I2C_CLK_SRC_DEFAULT;
        config.glitch_ignore_cnt = 7;
        config.flags.enable_internal_pullup = false;
        i2c_master_bus_handle_t bus = nullptr;
        auto error = i2c_new_master_bus(&config, &bus);
        if (error == ESP_OK) {
            error = runDisplay(inputs, bus);
            // runDisplay destroys its device handles before releasing the bus.
            const auto cleanup = i2c_del_master_bus(bus);
            if (cleanup != ESP_OK) {
                ESP_LOGE(TAG, "Bus cleanup failed: %s; display task stopping", esp_err_to_name(cleanup));
                vTaskDelete(nullptr);
                return; // Do not leak further bus allocations on repeated failures.
            }
        }
        ESP_LOGW(TAG, "Display unavailable: %s; retry in 5 s", esp_err_to_name(error));
        vTaskDelay(pdMS_TO_TICKS(5000) + 1);
    }
}
} // namespace

void startLcdDisplay(LcdDisplayInputs& inputs)
{
    if (xTaskCreate(displayTask, "lcd_display", 4096, &inputs, 1, nullptr) != pdPASS) {
        ESP_LOGE(TAG, "Display task creation failed; firmware continues");
    }
}
