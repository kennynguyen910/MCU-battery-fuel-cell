#include "fake_adc.hpp"
#include "board_config.hpp"
#include "wifi_manager.hpp"
#include "esp_log.h"

extern "C" void app_main()
{
    constexpr const char* TAG = "battery_monitor";
    ESP_LOGI(TAG, "Battery/Fuel Cell Monitor starting");

    // Static lifetime keeps event callbacks valid after app_main returns.
    static WiFiManager wifi;
    if (!wifi.init() || !wifi.start()) {
        ESP_LOGE(TAG, "Wi-Fi startup failed");
    }

    ESP_LOGI(TAG, "Board target: %s", board::config.target_name);

    FakeADC adc;
    ADCInterface& source = adc;
    if (!source.init()) {
        ESP_LOGE(TAG, "Fake ADC initialization failed");
        return;
    }

    SampleFrame frame{};
    if (!source.readFrame(frame)) {
        ESP_LOGE(TAG, "Fake ADC frame read failed");
        return;
    }
    for (int channel = 0; channel < 16; ++channel) {
        ESP_LOGI(TAG, "CH%d = %ld uV", channel + 1,
                 static_cast<long>(frame.channels[channel]));
    }
}
