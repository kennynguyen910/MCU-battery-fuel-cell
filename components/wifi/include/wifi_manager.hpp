#pragma once

#include <atomic>
#include <cstdint>
#include "esp_event.h"
#include "esp_netif.h"

// One manager owns the station driver. Call init/start from one application task;
// isConnected() may be called from any task. Keep the manager alive while in use.
// Future architecture: SampleFrame -> Packetizer -> Transport -> Wi-Fi or Ethernet.
// This class manages connectivity only and has no ADC or packet dependencies.
class WiFiManager
{
public:
    WiFiManager() = default;
    ~WiFiManager();
    WiFiManager(const WiFiManager&) = delete;
    WiFiManager& operator=(const WiFiManager&) = delete;

    bool init();
    bool start();
    bool isConnected() const;

private:
    static void eventHandler(void* arg, esp_event_base_t event_base,
                             int32_t event_id, void* event_data);
    void connect();
    void cleanup();

    std::atomic<bool> connected_{false};
    std::atomic<bool> running_{false};
    bool initialized_{false};
    bool driver_initialized_{false};
    esp_netif_t* station_{nullptr};
    esp_event_handler_instance_t wifi_handler_{nullptr};
    esp_event_handler_instance_t ip_handler_{nullptr};
};