#include "fake_adc.hpp"
#include "board_config.hpp"
#include "wifi_manager.hpp"
#include "acquisition_task.hpp"
#include "diagnostics.hpp"
#include "esp_log.h"

extern "C" void app_main()
{
    constexpr const char* TAG = "battery_monitor";
    ESP_LOGI(TAG, "Battery/Fuel Cell Monitor starting");
    ESP_LOGI(TAG, "Board target: %s", board::config.target_name);

    // Static lifetime keeps Wi-Fi callbacks and Stage 2 task references valid.
    static WiFiManager wifi;
    if (!wifi.init() || !wifi.start()) {
        ESP_LOGE(TAG, "Wi-Fi startup failed");
    }

    static FakeADC adc;
    ADCInterface& source = adc;
    if (!source.init()) {
        ESP_LOGE(TAG, "Fake ADC initialization failed");
        return;
    }

    static Diagnostics diagnostics;
    static Acquisition acquisition(source, diagnostics);
    if (!acquisition.start()) {
        ESP_LOGE(TAG, "Acquisition startup failed");
        return;
    }
    // All ongoing work belongs to tasks. Wi-Fi status never gates acquisition.
}