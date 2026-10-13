#include "sdkconfig.h"
#if CONFIG_BATTERY_ADC_SOURCE_REAL
#error "Real hardware ADC data is not yet available. Implement and validate the hardware driver first."
#endif
#if CONFIG_BATTERY_ADC_SOURCE_FAKE
#include "fake_adc.hpp"
#endif
#include "board_config.hpp"
#include "wifi_manager.hpp"
#include "acquisition_task.hpp"
#include "diagnostics.hpp"
#include "esp_log.h"
#include "packetizer_self_test.hpp"
#include "network_consumer.hpp"
#include "udp_config.hpp"
#include "ble_manager.hpp"
#include "ble_config.hpp"

// DEVELOPMENT ONLY: run the fixed packetizer self-test once at startup.
constexpr bool ENABLE_PACKETIZER_SELF_TEST = true;

extern "C" void app_main()
{
    constexpr const char* TAG = "battery_monitor";
    ESP_LOGI(TAG, "Battery/Fuel Cell Monitor starting");
    ESP_LOGI(TAG, "Board target: %s", board::config.target_name);

    if constexpr (ENABLE_PACKETIZER_SELF_TEST) {
        if (packetizer_test::runSelfTest()) {
            ESP_LOGI(TAG, "Packetizer self-test PASS (88-byte version 1 packet)");
        } else {
            ESP_LOGE(TAG, "Packetizer self-test FAIL");
        }
    }

    // Source selection does not disable independent Wi-Fi/BLE provisioning.
    static WiFiManager wifi;
    static Diagnostics diagnostics;
    static LatestFrameStore latest;
#if CONFIG_BATTERY_ADC_SOURCE_FAKE
    ESP_LOGW(TAG, "========================================");
    ESP_LOGW(TAG, "ADC SOURCE: FAKE / SIMULATED DATA");
    ESP_LOGW(TAG, "========================================");
    static FakeADC adc;
    ADCInterface& source = adc;
    if (!source.init()) {
        ESP_LOGE(TAG, "Fake ADC initialization failed");
        return;
    }

    static UdpTransport udp;
    static NetworkConsumer network_consumer(wifi, udp, diagnostics);
    ESP_LOGI(TAG, "UDP destination: configured Android collector (no default)");
    static Acquisition acquisition(source, diagnostics, &latest);
    if (!acquisition.start(&NetworkConsumer::consumeFrame, &network_consumer,
                           &NetworkConsumer::flushExpired)) {
        ESP_LOGE(TAG, "Acquisition startup failed");
        return;
    }
#else
    ESP_LOGW(TAG, "ADC SOURCE: DISABLED / NO MEASUREMENTS");
#endif
    // Enabled acquisition is already running before NVS or Wi-Fi initialization.
    if (!wifi.init() || !wifi.start()) {
        ESP_LOGE(TAG, "Wi-Fi startup failed; acquisition and BLE startup continue");
    }
    if constexpr (ble_config::ENABLE_BLE) {
        static BLEManager ble(latest, diagnostics,
            [](void* context) { return static_cast<WiFiManager*>(context)->isConnected(); },
            &wifi, wifi);
#if CONFIG_BATTERY_ADC_SOURCE_FAKE
        ble.setAcquisitionRunning(true);
#else
        ble.setAcquisitionRunning(false);
#endif
        if (!ble.init() || !ble.start()) {
            ESP_LOGE(TAG, "BLE startup failed; acquisition and Wi-Fi continue");
        }
    }
    // All ongoing work belongs to tasks. Wi-Fi status never gates acquisition.
}
