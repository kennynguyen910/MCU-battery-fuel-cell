#pragma once
#include "driver/i2c_master.h"

// One task owns an instance and its bus. Initialization bytes are shared by
// the physically verified fixed-message diagnostic and the cycling display.
class Lcd1602 {
public:
    Lcd1602() = default;
    ~Lcd1602();
    Lcd1602(const Lcd1602&) = delete;
    Lcd1602& operator=(const Lcd1602&) = delete;
    esp_err_t initialize(i2c_master_bus_handle_t bus);
    esp_err_t writeRows(const char rows[2][17]);
private:
    i2c_master_dev_handle_t lcd_ = nullptr;
    i2c_master_dev_handle_t backlight_ = nullptr;
    char cached_[2][17]{};
    bool cached_valid_[2]{};
};
esp_err_t showLcdStartup(i2c_master_bus_handle_t bus);
