#include <initializer_list>
// Native ESP-IDF implementation of the documented DFRobot V1.0 protocol.
// Reference: DFRobot/DFRobot_RGBLCD1602 (init, begin, command, write, setRGB).
// https://github.com/DFRobot/DFRobot_RGBLCD1602
#include "lcd1602.hpp"
#include <cstring>
#include "esp_rom_sys.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

namespace {
constexpr const char* TAG = "lcd1602";
constexpr unsigned LCD_ADDRESS = 0x3e;
constexpr unsigned BACKLIGHT_ADDRESS = 0x60;

// Include an extra tick so the minimum delay survives tick-phase rounding.
void pauseMs(unsigned ms)
{
    vTaskDelay(pdMS_TO_TICKS(ms + portTICK_PERIOD_MS - 1) + 1);
}

esp_err_t attach(i2c_master_bus_handle_t bus, unsigned address,
                 i2c_master_dev_handle_t* device)
{
    i2c_device_config_t config{};
    config.dev_addr_length = I2C_ADDR_BIT_LEN_7;
    config.device_address = address;
    config.scl_speed_hz = 100000;
    return i2c_master_bus_add_device(bus, &config, device);
}

esp_err_t pair(i2c_master_dev_handle_t device, unsigned address,
               uint8_t first, uint8_t second)
{
    const uint8_t bytes[] = {first, second};
    const auto error = i2c_master_transmit(device, bytes, sizeof(bytes), 50);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "Write to 0x%02X [%02X %02X] failed: %s",
                 address, first, second, esp_err_to_name(error));
    }
    return error;
}

esp_err_t command(i2c_master_dev_handle_t lcd, uint8_t value)
{
    const auto error = pair(lcd, LCD_ADDRESS, 0x80, value);
    pauseMs(value == 0x01 ? 2 : 1);
    return error;
}

esp_err_t line(i2c_master_dev_handle_t lcd, uint8_t cursor, const char* text)
{
    auto error = command(lcd, cursor);
    if (error != ESP_OK) return error;
    bool ended = false;
    for (unsigned column = 0; column < 16; ++column) {
        if (!ended && *text == '\0') ended = true;
        const uint8_t character = ended ? ' ' : *text++;
        error = pair(lcd, LCD_ADDRESS, 0x40, character);
        if (error != ESP_OK) return error;
        esp_rom_delay_us(100); // Processing margin without a full RTOS tick per character.
    }
    return ESP_OK;
}
} // namespace

Lcd1602::~Lcd1602()
{
    for (auto device : {lcd_, backlight_}) {
        if (device) {
            const auto error = i2c_master_bus_rm_device(device);
            if (error != ESP_OK) ESP_LOGW(TAG, "Device cleanup failed: %s", esp_err_to_name(error));
        }
    }
}

esp_err_t Lcd1602::initialize(i2c_master_bus_handle_t bus)
{
    if (lcd_ || backlight_) return ESP_ERR_INVALID_STATE;
    // This is an explicitly selected Gravity V1.0 profile, not chip-ID detection.
    for (const unsigned address : {LCD_ADDRESS, BACKLIGHT_ADDRESS}) {
        const auto error = i2c_master_probe(bus, address, 50);
        if (error != ESP_OK) {
            ESP_LOGE(TAG, "Required 0x%02X probe failed: %s", address, esp_err_to_name(error));
            return error;
        }
    }
    auto error = attach(bus, LCD_ADDRESS, &lcd_);
    if (error != ESP_OK) return error;
    error = attach(bus, BACKLIGHT_ADDRESS, &backlight_);
    if (error != ESP_OK) return error;

    pauseMs(50);
    // Two lines, 5x8 font: repeat the manufacturer's 0x28 function set.
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        error = command(lcd_, 0x28);
        if (error != ESP_OK) return error;
        if (attempt < 2) pauseMs(5);
    }
    for (const uint8_t value : {0x0c, 0x01, 0x06}) {
        error = command(lcd_, value);
        if (error != ESP_OK) return error;
    }
    // DFRobot's 0x60 profile: MODE1, LEDOUT, MODE2, then white RGB PWM.
    const uint8_t registers[][2] = {
        {0x00, 0x00}, {0x08, 0xff}, {0x01, 0x20},
        {0x04, 0xff}, {0x03, 0xff}, {0x02, 0xff}
    };
    for (const auto& reg : registers) {
        error = pair(backlight_, BACKLIGHT_ADDRESS, reg[0], reg[1]);
        if (error != ESP_OK) return error;
    }
    pauseMs(1);
    return ESP_OK;
}

esp_err_t Lcd1602::writeRows(const char rows[2][17])
{
    if (!lcd_) return ESP_ERR_INVALID_STATE;
    for (unsigned row = 0; row < 2; ++row) {
        char padded[17];
        bool ended = false;
        for (unsigned col = 0; col < 16; ++col) {
            if (!rows[row][col]) ended = true;
            padded[col] = ended ? ' ' : rows[row][col];
        }
        padded[16] = 0;
        if (cached_valid_[row] && std::memcmp(cached_[row], padded, 16) == 0) continue;
        const auto error = line(lcd_, row == 0 ? 0x80 : 0xc0, padded);
        if (error != ESP_OK) {
            cached_valid_[row] = false;
            return error;
        }
        std::memcpy(cached_[row], padded, sizeof(padded));
        cached_valid_[row] = true;
    }
    return ESP_OK;
}

esp_err_t showLcdStartup(i2c_master_bus_handle_t bus)
{
    Lcd1602 lcd;
    auto error = lcd.initialize(bus);
    if (error != ESP_OK) return error;
    const char startup[2][17] = {"BATTERY MONITOR", "ESP32 ONLINE"};
    error = lcd.writeRows(startup);
    if (error != ESP_OK) return error;

    // Address-only observation; never issue commands to the unexplained 0x70.
    const auto alias = i2c_master_probe(bus, 0x70, 20);
    if (alias == ESP_OK) {
        ESP_LOGI(TAG, "0x70 still ACKs after init; purpose unverified");
    } else if (alias == ESP_ERR_NOT_FOUND) {
        ESP_LOGI(TAG, "0x70 no longer ACKs; consistent with disabled All Call, not chip-ID proof");
    } else {
        ESP_LOGW(TAG, "Post-init 0x70 probe failed: %s", esp_err_to_name(alias));
    }
    return ESP_OK;
}
