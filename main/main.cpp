#include "fake_adc.hpp"
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
    static LatestFrameStore latest;
    static UdpTransport udp;
    static NetworkConsumer network_consumer(wifi, udp, diagnostics);
    ESP_LOGI(TAG, "UDP destination: %s:%u", udp_config::UDP_DESTINATION_IP,
             static_cast<unsigned>(udp_config::UDP_DESTINATION_PORT));
    static Acquisition acquisition(source, diagnostics, &latest);
    if (!acquisition.start(&NetworkConsumer::consumeFrame, &network_consumer,
                           &NetworkConsumer::flushExpired)) {
        ESP_LOGE(TAG, "Acquisition startup failed");
        return;
    }
    if constexpr (ble_config::ENABLE_BLE) {
        static BLEManager ble(latest, diagnostics,
            [](void* context) { return static_cast<WiFiManager*>(context)->isConnected(); },
            &wifi);
        ble.setAcquisitionRunning(true);
        if (!ble.init() || !ble.start()) {
            ESP_LOGE(TAG, "BLE startup failed; acquisition and Wi-Fi continue");
        }
    }
    // All ongoing work belongs to tasks. Wi-Fi status never gates acquisition.
}
