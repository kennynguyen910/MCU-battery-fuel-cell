#include "wifi_manager.hpp"

#include <cstring>
#include "esp_log.h"
#include "esp_wifi.h"

esp_err_t WiFiManager::scanNetworks(WiFiScanResult (&results)[MAX_SCAN_RESULTS],
                                    std::uint8_t& count, std::uint16_t& found)
{
    count = 0;
    found = 0;
    if (!running_.load() || !scan_done_) return ESP_ERR_WIFI_NOT_STARTED;
    // A timeout makes the event generation ambiguous. Require reinitialization
    // before another scan, so a delayed SCAN_DONE cannot complete a newer scan.
    if (scan_faulted_) return ESP_ERR_INVALID_STATE;
    bool expected = false;
    if (!scan_active_.compare_exchange_strong(expected, true)) return ESP_ERR_WIFI_STATE;
    // Do not abort a station connection in progress to scan. The client can retry.
    esp_err_t error = getState() == WiFiState::CONNECTING ? ESP_ERR_WIFI_STATE : ESP_OK;
    if (error == ESP_OK) {
        xSemaphoreTake(scan_done_, 0); // Drain any old completion before starting.
        scan_status_.store(1);
        wifi_scan_config_t config{};
        config.scan_type = WIFI_SCAN_TYPE_ACTIVE;
        config.scan_time.active.max = 120;
        error = esp_wifi_scan_start(&config, false);
        if (error == ESP_OK) {
            ESP_LOGI("wifi_scan", "Wi-Fi scan started");
            if (xSemaphoreTake(scan_done_, pdMS_TO_TICKS(15000)) != pdTRUE) {
                scan_faulted_ = true;
                const esp_err_t stop_error = esp_wifi_scan_stop();
                if (stop_error != ESP_OK)
                    ESP_LOGW("wifi_scan", "Stop scan failed: %s", esp_err_to_name(stop_error));
                error = ESP_ERR_TIMEOUT;
            } else if (scan_status_.load() != 0) {
                error = ESP_FAIL;
            }
            if (error == ESP_OK) error = esp_wifi_scan_get_ap_num(&found);
            // The driver returns strongest first and frees its entire AP list.
            // Fixed candidate cap keeps memory bounded, then deduplicate SSIDs.
            wifi_ap_record_t records[MAX_SCAN_RESULTS]{};
            std::uint16_t number = MAX_SCAN_RESULTS;
            if (error == ESP_OK && found != 0)
                error = esp_wifi_scan_get_ap_records(&number, records);
            else number = 0;
            if (error == ESP_OK) {
                for (unsigned i = 0; i < number; ++i) {
                    const auto& ap = records[i];
                    const size_t length = strnlen(reinterpret_cast<const char*>(ap.ssid), sizeof(ap.ssid));
                    if (length == 0 || length > 32) continue;
                    bool duplicate = false;
                    for (unsigned j = 0; j < count; ++j)
                        if (std::strcmp(results[j].ssid, reinterpret_cast<const char*>(ap.ssid)) == 0)
                            duplicate = true;
                    if (duplicate) continue;
                    auto& result = results[count++];
                    result = {};
                    std::memcpy(result.ssid, ap.ssid, length);
                    result.rssi = ap.rssi;
                    result.auth = static_cast<std::uint8_t>(ap.authmode);
                }
            }
            // Required on errors/empty lists too; no driver scan-list leak.
            const esp_err_t clear_error = esp_wifi_clear_ap_list();
            if (clear_error != ESP_OK) {
                ESP_LOGW("wifi_scan", "Clear scan list failed: %s", esp_err_to_name(clear_error));
                if (error == ESP_OK) error = clear_error;
            }
        }
    }
    scan_active_.store(false);
    // A disconnect during the scan deferred reconnect; resume the existing policy.
    if (getState() == WiFiState::CONNECTION_FAILED) connect();
    if (error != ESP_OK) ESP_LOGW("wifi_scan", "Scan failed: %s", esp_err_to_name(error));
    return error;
}
