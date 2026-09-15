#pragma once

namespace board {

// Temporary sentinel only: never pass a TBD pin to a GPIO or bus driver.
// Final pin assignments must be confirmed against the selected board schematic.
inline constexpr int GPIO_TBD = -1;

struct BoardConfig
{
    const char* target_name;
    int ADC_SCLK = GPIO_TBD;
    int ADC_MOSI = GPIO_TBD;
    int ADC_MISO = GPIO_TBD;
    int ADC_CS = GPIO_TBD;
    int ADC_DRDY = GPIO_TBD;
    int ADC_CONVST = GPIO_TBD;
    int ADC_RESET = GPIO_TBD;

    int ETH_SCLK = GPIO_TBD;
    int ETH_MOSI = GPIO_TBD;
    int ETH_MISO = GPIO_TBD;
    int ETH_CS = GPIO_TBD;
    int ETH_INT = GPIO_TBD;
    int ETH_RESET = GPIO_TBD;

    int CAN_TX = GPIO_TBD;
    int CAN_RX = GPIO_TBD;
    int OLED_SDA = GPIO_TBD;
    int OLED_SCL = GPIO_TBD;
    int STATUS_LED = GPIO_TBD;
};

// Future drivers use board::config.<signal> instead of hardcoded GPIO numbers.
extern const BoardConfig config;

} // namespace board