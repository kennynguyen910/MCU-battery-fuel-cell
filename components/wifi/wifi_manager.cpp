#include "wifi_manager.hpp"
#include "wifi_config.hpp"
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
    connected_.store(false);
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
    // NVS, esp_netif and the default event loop are shared with other components.
}

bool WiFiManager::init()
{
    if (initialized_) {
        return true;
    }
    ESP_LOGI(TAG, "Wi-Fi initialization started");

    esp_err_t error = nvs_flash_init();
    if (error == ESP_ERR_NVS_NO_FREE_PAGES || error == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "NVS requires erase and reinitialization");
        if (!check(nvs_flash_erase(), "Erase NVS")) {
            return false;
        }
        error = nvs_flash_init();
    }
    if (!check(error, "Initialize NVS") ||
        !check(esp_netif_init(), "Initialize network interfaces")) {
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
    static_assert(sizeof(WIFI_SSID) - 1 <= sizeof(station_config.sta.ssid),
                  "Wi-Fi SSID exceeds 32 bytes");
    static_assert(sizeof(WIFI_PASSWORD) - 1 <= sizeof(station_config.sta.password),
                  "Wi-Fi password exceeds 64 bytes");
    std::memcpy(station_config.sta.ssid, WIFI_SSID, sizeof(WIFI_SSID) - 1);
    std::memcpy(station_config.sta.password, WIFI_PASSWORD, sizeof(WIFI_PASSWORD) - 1);

    if (!check(esp_event_handler_instance_register(
                   WIFI_EVENT, ESP_EVENT_ANY_ID, &WiFiManager::eventHandler,
                   this, &wifi_handler_), "Register Wi-Fi handler") ||
        !check(esp_event_handler_instance_register(
                   IP_EVENT, ESP_EVENT_ANY_ID, &WiFiManager::eventHandler,
                   this, &ip_handler_), "Register IP handler") ||
        !check(esp_wifi_set_storage(WIFI_STORAGE_RAM), "Select RAM configuration") ||
        !check(esp_wifi_set_mode(WIFI_MODE_STA), "Configure station mode") ||
        !check(esp_wifi_set_config(WIFI_IF_STA, &station_config), "Configure credentials")) {
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
    if (!check(esp_wifi_start(), "Start Wi-Fi")) {
        running_.store(false);
        return false;
    }
    return true;
}

bool WiFiManager::isConnected() const
{
    return connected_.load();
}

void WiFiManager::connect()
{
    if (running_.load()) {
        ESP_LOGI(TAG, "Attempting connection");
        check(esp_wifi_connect(), "Connect Wi-Fi");
    }
}

void WiFiManager::eventHandler(void* arg, esp_event_base_t event_base,
                               int32_t event_id, void* event_data)
{
    auto* self = static_cast<WiFiManager*>(arg);
    if (event_base == WIFI_EVENT) {
        if (event_id == WIFI_EVENT_STA_START) {
            ESP_LOGI(TAG, "Wi-Fi station started");
            self->connect();
        } else if (event_id == WIFI_EVENT_STA_DISCONNECTED) {
            self->connected_.store(false);
            const auto* event = static_cast<const wifi_event_sta_disconnected_t*>(event_data);
            ESP_LOGW(TAG, "Wi-Fi disconnected (reason %u)",
                     event ? static_cast<unsigned>(event->reason) : 0U);
            if (self->running_.load()) {
                ESP_LOGI(TAG, "Reconnecting");
                self->connect();
            }
        } else if (event_id == WIFI_EVENT_STA_STOP) {
            self->connected_.store(false);
        }
    } else if (event_base == IP_EVENT) {
        if (event_id == IP_EVENT_STA_GOT_IP && self->running_.load()) {
            const auto* event = static_cast<const ip_event_got_ip_t*>(event_data);
            self->connected_.store(true);
            ESP_LOGI(TAG, "Wi-Fi connected");
            if (event) {
                ESP_LOGI(TAG, "Obtained IP address: " IPSTR, IP2STR(&event->ip_info.ip));
            }
        } else if (event_id == IP_EVENT_STA_LOST_IP) {
            self->connected_.store(false);
            ESP_LOGW(TAG, "Station lost IP address");
        }
    }
}