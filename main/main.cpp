#include "fake_adc.hpp"
#include "esp_log.h"

extern "C" void app_main()
{
    constexpr const char* TAG = "battery_monitor";
    ESP_LOGI(TAG, "Battery/Fuel Cell Monitor starting");

    FakeADC adc;
    if (!adc.init()) {
        ESP_LOGE(TAG, "Fake ADC initialization failed");
        return;
    }

    SampleFrame frame{};
    adc.readFrame(frame);
    ESP_LOGI(TAG, "Fake ADC ready: channel 0 = %ld, channel 15 = %ld",
             static_cast<long>(frame.channels[0]),
             static_cast<long>(frame.channels[15]));
}
