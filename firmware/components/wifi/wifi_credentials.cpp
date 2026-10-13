#include "wifi_manager.hpp"
#include "secure_zero.hpp"

#include <cstring>
#include <initializer_list>
#include "esp_log.h"
#include "nvs.h"

namespace {
constexpr const char* TAG = "wifi_credentials";
constexpr const char* NAMESPACE = "wifi_cfg";
constexpr const char* SSID_KEY = "ssid";
constexpr const char* PASSWORD_KEY = "password";
constexpr const char* COLLECTOR_KEY = "collector";

struct NvsHandle {
    nvs_handle_t value{};
    ~NvsHandle() { if (value) nvs_close(value); }
};

bool check(esp_err_t error, const char* operation)
{
    if (error == ESP_OK) return true;
    ESP_LOGE(TAG, "%s failed: %s", operation, esp_err_to_name(error));
    return false;
}

bool valid(const WiFiCredentials& credentials)
{
    const size_t ssid_length = strnlen(credentials.ssid, sizeof(credentials.ssid));
    const size_t password_length = strnlen(credentials.password, sizeof(credentials.password));
    if (ssid_length == 0 || ssid_length > 32 || password_length > 64) return false;
    if (credentials.collector_port && (credentials.collector_ipv4[0] == 0 ||
        credentials.collector_ipv4[0] == 127 || credentials.collector_ipv4[0] >= 224)) return false;
    // Open networks, WPA passphrases (8-63 bytes), or a 64-digit hexadecimal PSK.
    if (password_length == 0) return true;
    if (password_length < 8) return false;
    if (password_length == 64) {
        for (size_t i = 0; i < password_length; ++i) {
            const char c = credentials.password[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                  (c >= 'A' && c <= 'F'))) return false;
        }
    }
    return true;
}
}

esp_err_t WiFiManager::readCredentials(WiFiCredentials& credentials) const
{
    credentials = {};
    if (!nvs_ready_) return ESP_ERR_INVALID_STATE;
    NvsHandle handle;
    esp_err_t error = nvs_open(NAMESPACE, NVS_READONLY, &handle.value);
    if (error != ESP_OK) return error;
    WiFiCredentials stored{};
    SensitiveScope stored_scope(&stored, sizeof(stored));
    size_t ssid_size = sizeof(stored.ssid);
    size_t password_size = sizeof(stored.password);
    const esp_err_t ssid_error = nvs_get_str(handle.value, SSID_KEY, stored.ssid, &ssid_size);
    const esp_err_t password_error = nvs_get_str(handle.value, PASSWORD_KEY, stored.password, &password_size);
    // A real read failure takes precedence over a missing key (no automatic seed).
    if (ssid_error != ESP_OK && ssid_error != ESP_ERR_NVS_NOT_FOUND) return ssid_error;
    if (password_error != ESP_OK && password_error != ESP_ERR_NVS_NOT_FOUND) return password_error;
    if (ssid_error == ESP_ERR_NVS_NOT_FOUND || password_error == ESP_ERR_NVS_NOT_FOUND)
        return ESP_ERR_NVS_NOT_FOUND;
    std::uint8_t endpoint[6]{};
    size_t endpoint_size = sizeof(endpoint);
    const auto endpoint_error = nvs_get_blob(handle.value, COLLECTOR_KEY, endpoint, &endpoint_size);
    if (endpoint_error != ESP_OK && endpoint_error != ESP_ERR_NVS_NOT_FOUND) return endpoint_error;
    if (endpoint_error == ESP_OK) {
        if (endpoint_size != sizeof(endpoint)) return ESP_ERR_INVALID_ARG;
        std::memcpy(stored.collector_ipv4, endpoint, 4);
        stored.collector_port = (static_cast<unsigned>(endpoint[4]) << 8) | endpoint[5];
        if (!stored.collector_port) return ESP_ERR_INVALID_ARG;
    }
    if (!valid(stored)) return ESP_ERR_INVALID_ARG;
    credentials = stored;
    return ESP_OK;
}

bool WiFiManager::loadCredentials(WiFiCredentials& credentials) const
{
    const esp_err_t error = readCredentials(credentials);
    if (error == ESP_ERR_NVS_NOT_FOUND) return false;
    return check(error, "Read credentials");
}

bool WiFiManager::hasStoredCredentials() const
{
    WiFiCredentials credentials{};
    SensitiveScope credentials_scope(&credentials, sizeof(credentials));
    return loadCredentials(credentials);
}

bool WiFiManager::saveCredentials(const WiFiCredentials& credentials)
{
    if (!check(nvs_ready_ ? ESP_OK : ESP_ERR_INVALID_STATE, "NVS availability") ||
        !check(valid(credentials) ? ESP_OK : ESP_ERR_INVALID_ARG, "Validate credentials")) return false;
    NvsHandle handle;
    if (!check(nvs_open(NAMESPACE, NVS_READWRITE, &handle.value), "Open credential storage")) return false;
    // NVS commits are not multi-key transactions. Remove the SSID first so an
    // interrupted update cannot pair an old SSID with a newly written password.
    esp_err_t error = nvs_erase_key(handle.value, SSID_KEY);
    if (error != ESP_ERR_NVS_NOT_FOUND && !check(error, "Invalidate old SSID")) return false;
    credentials_stored_.store(false);
    publishCollector(WiFiCredentials{});
    if (!check(nvs_commit(handle.value), "Commit invalidation")) return false;
    if (credentials.collector_port) {
        const std::uint8_t endpoint[] = {credentials.collector_ipv4[0], credentials.collector_ipv4[1],
            credentials.collector_ipv4[2], credentials.collector_ipv4[3],
            static_cast<std::uint8_t>(credentials.collector_port >> 8),
            static_cast<std::uint8_t>(credentials.collector_port)};
        if (!check(nvs_set_blob(handle.value, COLLECTOR_KEY, endpoint, sizeof(endpoint)), "Write collector")) return false;
    } else {
        const auto erased = nvs_erase_key(handle.value, COLLECTOR_KEY);
        if (erased != ESP_ERR_NVS_NOT_FOUND && !check(erased, "Remove collector")) return false;
    }
    if (!check(nvs_commit(handle.value), "Commit collector") ||
        !check(nvs_set_str(handle.value, PASSWORD_KEY, credentials.password), "Write password") ||
        !check(nvs_commit(handle.value), "Commit password") ||
        !check(nvs_set_str(handle.value, SSID_KEY, credentials.ssid), "Write SSID") ||
        !check(nvs_commit(handle.value), "Commit credentials")) return false;
    credentials_stored_.store(true);
    publishCollector(credentials);
    ESP_LOGI(TAG, "Wi-Fi credentials saved");
    return true;
}

bool WiFiManager::clearCredentials()
{
    if (!check(nvs_ready_ ? ESP_OK : ESP_ERR_INVALID_STATE, "NVS availability")) return false;
    // Quiesce callbacks before publishing UNPROVISIONED; late events cannot
    // reconnect or overwrite the state. Shared NVS and the event loop stay alive.
    cleanup();
    publishCollector(WiFiCredentials{});
    NvsHandle handle;
    const esp_err_t opened = nvs_open(NAMESPACE, NVS_READWRITE, &handle.value);
    if (!check(opened, "Open credential storage")) return false;
    for (const char* key : {SSID_KEY, PASSWORD_KEY, COLLECTOR_KEY}) {
        const esp_err_t error = nvs_erase_key(handle.value, key);
        if (error != ESP_ERR_NVS_NOT_FOUND && !check(error, "Erase credential key")) return false;
        // Once either required key is absent, the saved pair is unusable even
        // if a later erase/commit fails. Keep the status cache conservative.
        credentials_stored_.store(false);
    }
    if (!check(nvs_commit(handle.value), "Commit credential removal")) return false;
    credentials_stored_.store(false);
    setState(WiFiState::UNPROVISIONED);
    ESP_LOGI(TAG, "Wi-Fi credentials cleared (UNPROVISIONED)");
    return true;
}

void WiFiManager::publishCollector(const WiFiCredentials& credentials)
{
    collector_version_.fetch_add(1);
    const auto* ip = credentials.collector_ipv4;
    collector_ip_.store((std::uint32_t(ip[0]) << 24) | (std::uint32_t(ip[1]) << 16) |
                       (std::uint32_t(ip[2]) << 8) | ip[3]);
    collector_port_.store(credentials.collector_port);
    collector_version_.fetch_add(1);
}

bool WiFiManager::getCollectorEndpoint(std::uint8_t out[4], std::uint16_t& port) const
{
    const auto version = collector_version_.load();
    if (version & 1) return false;
    const auto ip = collector_ip_.load();
    const auto stored_port = collector_port_.load();
    if (collector_version_.load() != version || !stored_port) return false;
    for (unsigned i = 0; i < 4; ++i) out[i] = ip >> (24 - i * 8);
    port = stored_port;
    return true;
}
