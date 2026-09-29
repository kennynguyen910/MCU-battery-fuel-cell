#include "wifi_manager.hpp"
#include "wifi_provisioning_config.hpp"
#if WIFI_ENABLE_DEVELOPMENT_SEED
#include "wifi_config.hpp"
#endif
#include "wifi_test_config.hpp"

#include <cstring>
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_wifi_default.h"
#include "nvs_flash.h"

namespace {
constexpr const char* TAG = "wifi_manager";

bool check(esp_err_t error, const char* operation)
{
    if (error == ESP_OK) {
        return true;
    }
    ESP_LOGE(TAG, "%s failed: %s", operation, esp_err_to_name(error));
    return false;
}
}

WiFiManager::~WiFiManager()
{
    cleanup();
}

void WiFiManager::cleanup()
{
    running_.store(false);
    ipv4_.store(0);
    state_.store(WiFiState::CONNECTION_FAILED);
    if (wifi_handler_) {
        check(esp_event_handler_instance_unregister(
                  WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_handler_), "Unregister Wi-Fi handler");
        wifi_handler_ = nullptr;
    }
    if (ip_handler_) {
        check(esp_event_handler_instance_unregister(
                  IP_EVENT, ESP_EVENT_ANY_ID, ip_handler_), "Unregister IP handler");
        ip_handler_ = nullptr;
    }
    if (driver_initialized_) {
        const esp_err_t error = esp_wifi_stop();
        if (error != ESP_ERR_WIFI_NOT_STARTED) {
            check(error, "Stop Wi-Fi");
        }
        check(esp_wifi_deinit(), "Deinitialize Wi-Fi");
        driver_initialized_ = false;
    }
    if (station_) {
        esp_netif_destroy_default_wifi(station_);
        station_ = nullptr;
    }
    initialized_ = false;
    state_.store(WiFiState::CONNECTION_FAILED);
    // NVS, esp_netif and the default event loop are shared with other components.
}

bool WiFiManager::init()
{
    if (initialized_) {
        return true;
    }
    state_.store(WiFiState::CONNECTION_FAILED);
    ESP_LOGI(TAG, "Wi-Fi initialization started");

    nvs_ready_ = false;
    scan_faulted_ = false;
    esp_err_t error = nvs_flash_init();
    if (error == ESP_ERR_NVS_NO_FREE_PAGES || error == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "NVS requires erase and reinitialization");
        if (!check(nvs_flash_erase(), "Erase NVS")) {
            return false;
        }
        error = nvs_flash_init();
    }
    if (!check(error, "Initialize NVS")) {
        return false;
    }
    nvs_ready_ = true;
    WiFiCredentials credentials{};
    error = readCredentials(credentials);
#if WIFI_ENABLE_DEVELOPMENT_SEED
    // Only a missing namespace/key permits seeding; never overwrite a read error.
    if (error == ESP_ERR_NVS_NOT_FOUND) {
        static_assert(sizeof(WIFI_SSID) <= sizeof(credentials.ssid), "SSID too long");
        static_assert(sizeof(WIFI_PASSWORD) <= sizeof(credentials.password), "Password too long");
        std::memcpy(credentials.ssid, WIFI_SSID, sizeof(WIFI_SSID));
        std::memcpy(credentials.password, WIFI_PASSWORD, sizeof(WIFI_PASSWORD));
        if (!saveCredentials(credentials)) {
            return false;
        }
        ESP_LOGI(TAG, "DEVELOPMENT: seeded Wi-Fi credentials into NVS");
        error = readCredentials(credentials);
    }
#endif
    if (error == ESP_ERR_NVS_NOT_FOUND) {
        state_.store(WiFiState::UNPROVISIONED);
        ESP_LOGI(TAG, "Wi-Fi credentials not configured (UNPROVISIONED)");
    } else if (!check(error, "Load Wi-Fi credentials")) {
        credentials_stored_.store(false);
        return false;
    }
    station_configured_ = error == ESP_OK;
    credentials_stored_.store(station_configured_);
    if (station_configured_) ESP_LOGI(TAG, "Wi-Fi credentials loaded from NVS");
    // The unprovisioned radio runs in station mode for explicit scans only.
    // No connect() call is made without a valid loaded configuration.
    if (!scan_done_) scan_done_ = xSemaphoreCreateBinaryStatic(&scan_done_storage_);
    if (!check(esp_netif_init(), "Initialize network interfaces")) {
        return false;
    }

    error = esp_event_loop_create_default();
    if (error != ESP_ERR_INVALID_STATE && !check(error, "Create default event loop")) {
        return false;
    }

    esp_netif_config_t netif_config = ESP_NETIF_DEFAULT_WIFI_STA();
    station_ = esp_netif_new(&netif_config);
    if (!station_) {
        ESP_LOGE(TAG, "Create station interface failed");
        return false;
    }
    // Equivalent to the default station helper, with recoverable error handling.
    if (!check(esp_netif_attach_wifi_station(station_), "Attach station interface") ||
        !check(esp_wifi_set_default_wifi_sta_handlers(), "Set default station handlers")) {
        cleanup();
        return false;
    }
    wifi_init_config_t driver_config = WIFI_INIT_CONFIG_DEFAULT();
    if (!check(esp_wifi_init(&driver_config), "Initialize Wi-Fi driver")) {
        cleanup();
        return false;
    }
    driver_initialized_ = true;
    if constexpr (wifi_test_config::HIGH_THROUGHPUT_TEST_MODE) {
        if (!check(esp_wifi_set_ps(WIFI_PS_NONE), "Disable Wi-Fi power save for test")) {
            cleanup();
            return false;
        }
        ESP_LOGI(TAG, "DEVELOPMENT throughput test: Wi-Fi power save disabled (WIFI_PS_NONE)");
    }

    wifi_config_t station_config{};
    // ESP-IDF fields are length-bounded byte arrays; a maximum-length SSID or
    // raw 64-hex PSK fills its field. Our source strings always have a terminator.
    std::memcpy(station_config.sta.ssid, credentials.ssid, std::strlen(credentials.ssid));
    std::memcpy(station_config.sta.password, credentials.password, std::strlen(credentials.password));

    if (!check(esp_event_handler_instance_register(
                   WIFI_EVENT, ESP_EVENT_ANY_ID, &WiFiManager::eventHandler,
                   this, &wifi_handler_), "Register Wi-Fi handler") ||
        !check(esp_event_handler_instance_register(
                   IP_EVENT, ESP_EVENT_ANY_ID, &WiFiManager::eventHandler,
                   this, &ip_handler_), "Register IP handler") ||
        !check(esp_wifi_set_storage(WIFI_STORAGE_RAM), "Select RAM configuration") ||
        !check(esp_wifi_set_mode(WIFI_MODE_STA), "Configure station mode") ||
        (station_configured_ &&
         !check(esp_wifi_set_config(WIFI_IF_STA, &station_config), "Configure credentials"))) {
        cleanup();
        return false;
    }
    initialized_ = true;
    return true;
}

bool WiFiManager::start()
{
    if (!initialized_) {
        ESP_LOGE(TAG, "Call init() before start()");
        return false;
    }
    if (running_.exchange(true)) {
        return true;
    }
    state_.store(station_configured_ ? WiFiState::CONNECTING : WiFiState::UNPROVISIONED);
    if (!check(esp_wifi_start(), "Start Wi-Fi")) {
        state_.store(WiFiState::CONNECTION_FAILED);
        running_.store(false);
        return false;
    }
    return true;
}

bool WiFiManager::isConnected() const
{
    return getState() == WiFiState::CONNECTED;
}

WiFiState WiFiManager::getState() const
{
    return state_.load();
}

void WiFiManager::connect()
{
    if (running_.load() && station_configured_ && !scan_active_.load()) {
        ESP_LOGI(TAG, "Attempting connection");
        state_.store(WiFiState::CONNECTING);
        if (!check(esp_wifi_connect(), "Connect Wi-Fi")) {
            state_.store(WiFiState::CONNECTION_FAILED);
        }
    }
}

void WiFiManager::eventHandler(void* arg, esp_event_base_t event_base,
                               int32_t event_id, void* event_data)
{
    auto* self = static_cast<WiFiManager*>(arg);
    if (!self->running_.load()) {
        return;
    }
    if (event_base == WIFI_EVENT) {
        if (event_id == WIFI_EVENT_SCAN_DONE) {
            if (self->scan_active_.load()) {
                const auto* event = static_cast<const wifi_event_sta_scan_done_t*>(event_data);
                self->scan_status_.store(event ? event->status : 1);
                xSemaphoreGive(self->scan_done_);
            }
        } else if (event_id == WIFI_EVENT_STA_START) {
            ESP_LOGI(TAG, "Wi-Fi station started");
            self->connect();
        } else if (event_id == WIFI_EVENT_STA_DISCONNECTED) {
            self->ipv4_.store(0);
            self->state_.store(WiFiState::CONNECTION_FAILED);
            const auto* event = static_cast<const wifi_event_sta_disconnected_t*>(event_data);
            ESP_LOGW(TAG, "Wi-Fi disconnected (reason %u)",
                     event ? static_cast<unsigned>(event->reason) : 0U);
            if (self->running_.load()) {
                ESP_LOGI(TAG, "Reconnecting");
                self->connect();
            }
        } else if (event_id == WIFI_EVENT_STA_STOP) {
            self->ipv4_.store(0);
            self->state_.store(WiFiState::CONNECTION_FAILED);
        }
    } else if (event_base == IP_EVENT) {
        if (event_id == IP_EVENT_STA_GOT_IP && self->running_.load()) {
            const auto* event = static_cast<const ip_event_got_ip_t*>(event_data);
            self->ipv4_.store(event ? event->ip_info.ip.addr : 0);
            self->state_.store(WiFiState::CONNECTED);
            ESP_LOGI(TAG, "Wi-Fi connected");
            if (event) {
                ESP_LOGI(TAG, "Obtained IP address: " IPSTR, IP2STR(&event->ip_info.ip));
            }
        } else if (event_id == IP_EVENT_STA_LOST_IP) {
            self->ipv4_.store(0);
            self->state_.store(WiFiState::CONNECTION_FAILED);
            ESP_LOGW(TAG, "Station lost IP address");
        }
    }
}
void WiFiManager::getIPv4(std::uint8_t out[4]) const
{
    // esp_ip4_addr_t is already in network byte order in memory.
    const std::uint32_t address = isConnected() ? ipv4_.load() : 0;
    std::memcpy(out, &address, sizeof(address));
    if (!isConnected()) std::memset(out, 0, sizeof(address));
}
