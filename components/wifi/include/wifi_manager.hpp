#pragma once

#include <atomic>
#include <cstdint>
#include "esp_event.h"
#include "esp_netif.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

enum class WiFiState {
    UNPROVISIONED,
    CONNECTING,
    CONNECTED,
    CONNECTION_FAILED
};

// Extra byte keeps application strings terminated even at the Wi-Fi field limits.
struct WiFiCredentials {
    char ssid[33]{};
    char password[65]{};
};

struct WiFiScanResult {
    char ssid[33]{};
    std::int8_t rssi{};
    std::uint8_t auth{}; // Raw ESP-IDF auth mode; protocol mapping belongs to BLE.
};

// One manager owns the station driver. Call init/start from one application task;
// All lifecycle and credential methods must run serially on one control task,
// never in an ISR, acquisition task, or Wi-Fi event callback. State queries are
// atomic and may run on any task. Keep the manager alive while in use.
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
    WiFiState getState() const;
    bool credentialsStored() const { return credentials_stored_.load(); }
    void getIPv4(std::uint8_t out[4]) const;
    static constexpr unsigned MAX_SCAN_RESULTS = 15;
    // One communications worker only; never a GATT callback or acquisition task.
    // Starts a nonblocking driver scan, then sleeps on SCAN_DONE (15 s bound).
    // Lifecycle/storage mutations must not run concurrently with this method.
    esp_err_t scanNetworks(WiFiScanResult (&results)[MAX_SCAN_RESULTS],
                           std::uint8_t& count, std::uint16_t& found);

    // Call init() first to initialize shared NVS (even if no credentials exist).
    // Missing credentials return false, with a zeroed output; errors are logged.
    bool loadCredentials(WiFiCredentials& credentials) const;
    bool hasStoredCredentials() const;
    // Persists only; does not change an active connection. Reboot to apply.
    bool saveCredentials(const WiFiCredentials& credentials);
    // Stops Wi-Fi and removes only our credential keys. Disable development
    // seeding before clearing, otherwise the next init() will seed again.
    bool clearCredentials();

private:
    static void eventHandler(void* arg, esp_event_base_t event_base,
                             int32_t event_id, void* event_data);
    void connect();
    void cleanup();

    esp_err_t readCredentials(WiFiCredentials& credentials) const;

    std::atomic<WiFiState> state_{WiFiState::UNPROVISIONED};
    std::atomic<bool> credentials_stored_{false};
    std::atomic<std::uint32_t> ipv4_{0};
    std::atomic<bool> scan_active_{false};
    std::atomic<std::uint32_t> scan_status_{0};
    StaticSemaphore_t scan_done_storage_{};
    SemaphoreHandle_t scan_done_ = nullptr;
    bool scan_faulted_{false}; // Worker-owned; init resets before worker startup.
    bool station_configured_{false}; // Set before start; lifecycle control task only.
    bool nvs_ready_{false};
    std::atomic<bool> running_{false};
    bool initialized_{false};
    bool driver_initialized_{false};
    esp_netif_t* station_{nullptr};
    esp_event_handler_instance_t wifi_handler_{nullptr};
    esp_event_handler_instance_t ip_handler_{nullptr};
};