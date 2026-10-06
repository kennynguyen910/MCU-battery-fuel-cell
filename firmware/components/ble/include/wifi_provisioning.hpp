#pragma once

#include "wifi_manager.hpp"
#include "provisioning_protocol.hpp"
#include "credential_staging.hpp"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "host/ble_gatt.h"
#include "host/ble_gap.h"
#include "nimble/nimble_npl.h"

enum class ProvisioningState { IDLE, SCANNING, RECEIVING_CREDENTIALS, APPLYING_CREDENTIALS };

// Firmware lifetime, one BLE client. All BLE state and sends belong to the
// NimBLE host task. The sole worker owns scan results until its completion event
// transfers them to the host; the provisioning state prevents reuse until delivery finishes.
class WiFiProvisioning {
public:
    explicit WiFiProvisioning(WiFiManager& wifi) : wifi_(wifi) {}
    WiFiProvisioning(const WiFiProvisioning&) = delete;
    WiFiProvisioning& operator=(const WiFiProvisioning&) = delete;
    void configureService(ble_gatt_svc_def& service);
    bool start();
    void gapEvent(const ble_gap_event& event);
    void reset();
private:
    static int access(std::uint16_t, std::uint16_t, ble_gatt_access_ctxt*, void*);
    static void worker(void* arg);
    static void scanReady(ble_npl_event* event);
    static void sendNext(ble_npl_event* event);
    void encodeStatus(std::uint8_t (&out)[provisioning_protocol::STATUS_SIZE]);
    bool notify(std::uint16_t handle, bool subscribed, const std::uint8_t* data, unsigned length);
    void notifyStatus();
    bool response(std::uint8_t opcode, std::uint8_t transaction, std::uint8_t command, std::uint8_t result);
    void fail(std::uint8_t transaction, std::uint8_t command, std::uint8_t error);
    void finish();
    void nextFragment();
    WiFiManager& wifi_;
    ble_gatt_chr_def characteristics_[4]{};
    std::uint16_t control_handle_{}, data_handle_{}, status_handle_{};
    std::uint16_t connection_ = BLE_HS_CONN_HANDLE_NONE;
    bool control_subscribed_{}, data_subscribed_{}, status_subscribed_{};
    std::uint32_t session_{}, request_session_{};
    std::uint8_t transaction_{}, last_error_{};
    ProvisioningState state_ = ProvisioningState::IDLE;
    bool delivering_{};
    provisioning_protocol::CredentialStaging staged_{};
    WiFiCredentials worker_credentials_{};
    std::uint8_t work_opcode_ = provisioning_protocol::START_SCAN;
    std::uint8_t work_error_{};
    ble_npl_callout timeout_callout_{};
    bool credential_runtime_ready_{};
    bool initializeCredentials();
    bool provisioningSecuritySatisfied() const;
    bool authorizeCredentials(std::uint8_t transaction, std::uint8_t opcode);
    int credentialControl(const std::uint8_t* header);
    int credentialData(ble_gatt_access_ctxt* ctxt);
    void discardCredentials();
    bool armCredentialTimeout();
    void runCredentialWork();
    void credentialWorkReady();
    static void credentialTimeout(ble_npl_event* event);
    static void wifiStateChanged(void* context, WiFiState state);
    static void statusChanged(ble_npl_event* event);
    struct StateNotice {
        WiFiState state;
        std::uint32_t session;
        bool stored;
        std::uint8_t ipv4[4];
    };
    static constexpr unsigned STATUS_QUEUE_LENGTH = 8;
    StaticQueue_t status_queue_storage_{};
    std::uint8_t status_queue_bytes_[STATUS_QUEUE_LENGTH * sizeof(StateNotice)]{};
    QueueHandle_t status_queue_ = nullptr;
    ble_npl_event status_event_{};
    std::atomic<std::uint32_t> observer_session_{0};
    std::atomic<bool> status_resync_{false};
    std::atomic<bool> scanning_{false};
    WiFiScanResult results_[WiFiManager::MAX_SCAN_RESULTS]{};
    std::uint8_t result_count_{}, reported_{}, result_index_{}, offset_{};
    std::uint16_t found_{};
    esp_err_t scan_error_ = ESP_OK;
    ble_npl_event ready_event_{};
    ble_npl_callout send_callout_{};
    bool callout_initialized_{};
    static constexpr unsigned STACK_BYTES = 6144;
    StackType_t stack_[STACK_BYTES / sizeof(StackType_t)]{};
    StaticTask_t task_storage_{};
    TaskHandle_t task_ = nullptr;
};
