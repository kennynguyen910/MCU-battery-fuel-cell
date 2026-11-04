#include "sdkconfig.h"
#include "board_config.hpp"
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#if CONFIG_BATTERY_LCD_STARTUP_TEST
esp_err_t showLcdStartup(i2c_master_bus_handle_t bus);
#endif

namespace {
constexpr const char* TAG = "display_probe";

void probeTask(void*)
{
    const int sda = board::config.DISPLAY_SDA;
    const int scl = board::config.DISPLAY_SCL;
    if (sda < 0 || scl < 0 || sda == scl ||
        !GPIO_IS_VALID_OUTPUT_GPIO(sda) || !GPIO_IS_VALID_OUTPUT_GPIO(scl)) {
        ESP_LOGE(TAG, "Invalid/unassigned display pins SDA=%d SCL=%d; skipping", sda, scl);
        vTaskDelete(nullptr);
        return;
    }

    i2c_master_bus_config_t config{};
    config.i2c_port = -1; // Allocate an unused controller.
    config.sda_io_num = static_cast<gpio_num_t>(sda);
    config.scl_io_num = static_cast<gpio_num_t>(scl);
    config.clk_source = I2C_CLK_SRC_DEFAULT;
    config.glitch_ignore_cnt = 7;
    // External pull-ups to a verified GPIO-safe voltage are required.
    config.flags.enable_internal_pullup = false;
    i2c_master_bus_handle_t bus = nullptr;
    const esp_err_t init = i2c_new_master_bus(&config, &bus);
    if (init != ESP_OK) {
        ESP_LOGE(TAG, "I2C initialization failed: %s", esp_err_to_name(init));
        vTaskDelete(nullptr);
        return;
    }

    ESP_LOGI(TAG, "I2C diagnostic SDA=%d SCL=%d; probing 7-bit addresses 0x08..0x77",
             sda, scl);
    unsigned found = 0;
    bool completed = true;
    for (unsigned address = 0x08; address <= 0x77; ++address) {
        // Address-only probe: no controller-specific commands or display data.
        const esp_err_t result = i2c_master_probe(bus, address, 20);
        if (result == ESP_OK) {
            ++found;
            ESP_LOGI(TAG, "ACK at 7-bit address 0x%02X (controller NOT identified)", address);
        } else if (result != ESP_ERR_NOT_FOUND) {
            ESP_LOGE(TAG, "Probe 0x%02X failed: %s; stopping scan",
                     address, esp_err_to_name(result));
            completed = false;
            break;
        }
        vTaskDelay(1); // Yield; never execute in acquisition or interrupt context.
    }
    ESP_LOGI(TAG, "Scan %s: %u responding address(es)", completed ? "complete" : "aborted", found);
#if CONFIG_BATTERY_LCD_STARTUP_TEST
    if (completed) {
        const auto result = showLcdStartup(bus);
        if (result == ESP_OK) {
            ESP_LOGI("lcd1602", "LCD initialization and startup writes succeeded; visual confirmation pending");
        } else {
            ESP_LOGE("lcd1602", "LCD initialization failed: %s; firmware continues", esp_err_to_name(result));
        }
    } else {
        ESP_LOGE("lcd1602", "LCD initialization skipped because the scan failed");
    }
#else
    ESP_LOGW(TAG, "LCD protocol unverified: no LCD initialization or text commands sent");
#endif
    const esp_err_t cleanup = i2c_del_master_bus(bus);
    if (cleanup != ESP_OK) {
        ESP_LOGE(TAG, "I2C cleanup failed: %s", esp_err_to_name(cleanup));
    }
    vTaskDelete(nullptr);
}
} // namespace

void startDisplayProbe()
{
    if (xTaskCreate(probeTask, "display_probe", 3072, nullptr, 1, nullptr) != pdPASS) {
        ESP_LOGE(TAG, "Cannot start I2C diagnostic task; firmware startup continues");
    }
}
