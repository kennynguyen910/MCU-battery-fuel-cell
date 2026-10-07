#include "wifi_provisioning.hpp"
#include "provisioning_config.hpp"
#include "secure_zero.hpp"

#include <cstring>
#include "esp_log.h"
#include "esp_timer.h"
#include "host/ble_hs.h"
#include "nimble/nimble_port.h"

namespace {
using namespace provisioning_protocol;
constexpr const char* TAG = "wifi_provisioning";
std::uint32_t nowMs() { return static_cast<std::uint32_t>(esp_timer_get_time() / 1000); }
std::uint8_t stateByte(WiFiState state)
{
    switch (state) {
    case WiFiState::UNPROVISIONED: return 0;
    case WiFiState::CONNECTING: return 1;
    case WiFiState::CONNECTED: return 2;
    case WiFiState::CONNECTION_FAILED: return 3;
    }
    return 3;
}
}

bool WiFiProvisioning::initializeCredentials()
{
#if BATTERY_MONITOR_ALLOW_INSECURE_PROVISIONING_DEV
    ESP_LOGW(TAG, "DEVELOPMENT WARNING: insecure Wi-Fi provisioning ENABLED; disable for final firmware");
#endif
    status_queue_ = xQueueCreateStatic(STATUS_QUEUE_LENGTH, sizeof(StateNotice),
                                      status_queue_bytes_, &status_queue_storage_);
    ble_npl_event_init(&status_event_, statusChanged, this);
    if (!status_queue_ || ble_npl_callout_init(&timeout_callout_,
            nimble_port_get_dflt_eventq(), credentialTimeout, this) != 0) return false;
    return wifi_.setStateListener(wifiStateChanged, this);
}

bool WiFiProvisioning::provisioningSecuritySatisfied() const
{
    ble_gap_conn_desc connection{};
    if (connection_ == BLE_HS_CONN_HANDLE_NONE || ble_gap_conn_find(connection_, &connection) != 0)
        return false;
#if BATTERY_MONITOR_ALLOW_INSECURE_PROVISIONING_DEV
    return true;
#else
    return connection.sec_state.encrypted && connection.sec_state.authenticated;
#endif
}

bool WiFiProvisioning::authorizeCredentials(std::uint8_t transaction, std::uint8_t opcode)
{
    if (provisioningSecuritySatisfied()) return true;
    discardCredentials();
    fail(transaction, opcode, SECURITY_REQUIRED);
    notifyStatus();
    return false;
}

void WiFiProvisioning::discardCredentials()
{
    if (credential_runtime_ready_) ble_npl_callout_stop(&timeout_callout_);
    secureZero(&staged_, sizeof(staged_));
    if (state_ == ProvisioningState::RECEIVING_CREDENTIALS) state_ = ProvisioningState::IDLE;
}

bool WiFiProvisioning::armCredentialTimeout()
{
    if (ble_npl_callout_reset(&timeout_callout_, ble_npl_time_ms_to_ticks32(CREDENTIAL_TIMEOUT_MS)) == 0)
        return true;
    const auto transaction = staged_.transaction;
    discardCredentials();
    fail(transaction, BEGIN_CREDENTIALS, INTERNAL_ERROR);
    return false;
}

void WiFiProvisioning::credentialTimeout(ble_npl_event* event)
{
    auto& self = *static_cast<WiFiProvisioning*>(ble_npl_event_get_arg(event));
    if (self.state_ != ProvisioningState::RECEIVING_CREDENTIALS) return;
    const auto now = nowMs();
    if (!self.staged_.expired(now)) {
        // A timer event already queued before a new fragment must not expire it.
        const auto remaining = CREDENTIAL_TIMEOUT_MS - static_cast<std::uint32_t>(now - self.staged_.last_activity);
        if (ble_npl_callout_reset(&self.timeout_callout_, ble_npl_time_ms_to_ticks32(remaining)) == 0) return;
    }
    const auto transaction = self.staged_.transaction;
    self.discardCredentials();
    self.fail(transaction, BEGIN_CREDENTIALS, TIMEOUT);
    self.notifyStatus();
}

int WiFiProvisioning::credentialControl(const std::uint8_t* header)
{
    const auto opcode = header[1], transaction = header[2];
    if (opcode != CANCEL && !authorizeCredentials(transaction, opcode)) return 0;
    if (!credential_runtime_ready_ || !task_) {
        fail(transaction, opcode, INTERNAL_ERROR); return 0;
    }
    std::uint8_t error = OK;
    if (opcode == BEGIN_CREDENTIALS || opcode == CLEAR_CREDENTIALS) {
        if (state_ != ProvisioningState::IDLE && state_ != ProvisioningState::RECEIVING_CREDENTIALS)
            error = OPERATION_BUSY;
    } else if (state_ == ProvisioningState::SCANNING || state_ == ProvisioningState::APPLYING_CREDENTIALS) {
        error = OPERATION_BUSY;
    } else {
        error = staged_.expired(nowMs()) ? TIMEOUT :
            opcode == COMMIT_CREDENTIALS ? staged_.commit(transaction) : staged_.checkTransaction(transaction);
    }
    if (error != OK) {
        if (error == TIMEOUT || (opcode == COMMIT_CREDENTIALS && error != OPERATION_BUSY))
            discardCredentials();
        fail(transaction, opcode, error); notifyStatus(); return 0;
    }
    last_error_ = OK;
    if (opcode == BEGIN_CREDENTIALS) {
        discardCredentials();
        staged_.begin(transaction, nowMs());
        state_ = ProvisioningState::RECEIVING_CREDENTIALS;
        if (!armCredentialTimeout()) { notifyStatus(); return 0; }
    } else if (opcode == CANCEL) {
        discardCredentials(); // Never touches saved credentials or the Wi-Fi link.
    } else {
        // Ownership of this separate copy transfers to the existing worker.
        // Reset/disconnect must never wipe worker memory while it is being used.
        secureZero(&worker_credentials_, sizeof(worker_credentials_));
        if (opcode == COMMIT_CREDENTIALS) {
            std::memcpy(worker_credentials_.ssid, staged_.ssid, sizeof(staged_.ssid));
            std::memcpy(worker_credentials_.password, staged_.password, sizeof(staged_.password));
        }
        discardCredentials();
        state_ = ProvisioningState::APPLYING_CREDENTIALS;
        work_opcode_ = opcode;
        work_apply_ = false;
        transaction_ = transaction;
        request_session_ = session_;
        xTaskNotifyGive(task_);
    }
    // Persistent operations respond only from credentialWorkReady after NVS.
    if (opcode == BEGIN_CREDENTIALS || opcode == CANCEL) {
        if (!response(ACK, transaction, opcode, OK)) {
            discardCredentials();
            last_error_ = INTERNAL_ERROR;
            return BLE_ATT_ERR_INSUFFICIENT_RES;
        }
    }
    notifyStatus();
    return 0;
}

int WiFiProvisioning::credentialData(ble_gatt_access_ctxt* ctxt)
{
    // Copy only the fixed header until authorization has been checked.
    const unsigned length = OS_MBUF_PKTLEN(ctxt->om);
    std::uint8_t header[DATA_HEADER_SIZE]{};
    const unsigned prefix = length < sizeof(header) ? length : sizeof(header);
    if (prefix && os_mbuf_copydata(ctxt->om, 0, prefix, header) != 0) return BLE_ATT_ERR_UNLIKELY;
    if (!authorizeCredentials(header[2], BEGIN_CREDENTIALS)) return 0;
    if (!control_subscribed_) {
        discardCredentials(); last_error_ = INTERNAL_ERROR; return BLE_ATT_ERR_UNLIKELY;
    }
    if (state_ == ProvisioningState::APPLYING_CREDENTIALS || state_ == ProvisioningState::SCANNING) {
        fail(header[2], BEGIN_CREDENTIALS, OPERATION_BUSY); return 0;
    }
    if (length < DATA_HEADER_SIZE || length > NOTIFICATION_SIZE) {
        discardCredentials();
        fail(header[2], BEGIN_CREDENTIALS, FRAGMENT_ERROR); notifyStatus(); return 0;
    }
    std::uint8_t bytes[NOTIFICATION_SIZE]{};
    SensitiveScope bytes_scope(bytes, sizeof(bytes));
    if (os_mbuf_copydata(ctxt->om, 0, length, bytes) != 0) {
        discardCredentials(); return BLE_ATT_ERR_UNLIKELY;
    }
    const auto error = staged_.accept(bytes, length, nowMs());
    if (error != OK) {
        discardCredentials(); // Restart with BEGIN after any malformed transaction.
        fail(header[2], BEGIN_CREDENTIALS, error);
        notifyStatus();
        return 0;
    }
    armCredentialTimeout();
    return 0; // ATT Write Response acknowledges the fragment; no Control ACK.
}

void WiFiProvisioning::runCredentialWork()
{
    work_error_ = OK;
    if (work_apply_) {
        if (!wifi_.applyStoredCredentials())
            work_error_ = work_opcode_ == COMMIT_CREDENTIALS ? WIFI_CONNECTION_FAILED : INTERNAL_ERROR;
        return;
    }
    // A queued request from a disconnected client must not start an NVS write.
    // Once NVS work starts, disconnect cannot undo the submitted durable command.
    if (request_session_ != observer_session_.load()) {
        secureZero(&worker_credentials_, sizeof(worker_credentials_));
        work_error_ = NO_STAGED_CREDENTIALS;
        return;
    }
    if (work_opcode_ == COMMIT_CREDENTIALS) {
        if (!wifi_.saveCredentials(worker_credentials_)) work_error_ = NVS_SAVE_FAILED;
        // saveCredentials no longer needs this copy, even if the save failed.
        secureZero(&worker_credentials_, sizeof(worker_credentials_));
    } else {
        if (!wifi_.clearCredentials()) work_error_ = NVS_SAVE_FAILED;
        secureZero(&worker_credentials_, sizeof(worker_credentials_));
    }
}

void WiFiProvisioning::credentialWorkReady()
{
    const bool same_session = request_session_ == session_ && connection_ != BLE_HS_CONN_HANDLE_NONE;
    if (!work_apply_ && work_error_ == OK) {
        // NVS is durable before ACK, and connection starts only after this send.
        // If notification fails/disconnects, still apply the saved credentials.
        if (same_session && !response(ACK, transaction_, work_opcode_, OK)) last_error_ = INTERNAL_ERROR;
        work_apply_ = true;
        xTaskNotifyGive(task_);
        return;
    }
    state_ = ProvisioningState::IDLE;
    if (same_session) {
        if (work_error_ != OK) {
            if (!work_apply_) fail(transaction_, work_opcode_, work_error_);
            else last_error_ = work_error_; // ACK meant NVS success, never Wi-Fi success.
        }
        notifyStatus();
    }
}

void WiFiProvisioning::wifiStateChanged(void* context, WiFiState state)
{
    auto& self = *static_cast<WiFiProvisioning*>(context);
    StateNotice notice{};
    notice.state = state;
    notice.session = self.observer_session_.load();
    notice.stored = self.wifi_.credentialsStored();
    if (state == WiFiState::CONNECTED) {
        self.wifi_.getIPv4(notice.ipv4);
        self.wifi_.getConnectedNetwork(notice.network);
    }
    if (xQueueSend(self.status_queue_, &notice, 0) != pdTRUE) self.status_resync_.store(true);
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &self.status_event_);
}

void WiFiProvisioning::statusChanged(ble_npl_event* event)
{
    auto& self = *static_cast<WiFiProvisioning*>(ble_npl_event_get_arg(event));
    StateNotice notice{};
    // Bounded drain keeps Wi-Fi events from monopolizing the NimBLE host task.
    for (unsigned i = 0; i < STATUS_QUEUE_LENGTH && xQueueReceive(self.status_queue_, &notice, 0) == pdTRUE; ++i) {
        if (notice.session != self.session_ || self.connection_ == BLE_HS_CONN_HANDLE_NONE) continue;
        if (notice.state == WiFiState::CONNECTION_FAILED) self.last_error_ = WIFI_CONNECTION_FAILED;
        else if (notice.state == WiFiState::CONNECTED && self.last_error_ == WIFI_CONNECTION_FAILED)
            self.last_error_ = OK;
        if (notice.state == WiFiState::CONNECTED)
            self.notifyNetworkInfo(notice.network, notice.ipv4);
        if (!self.status_subscribed_) continue;
        std::uint8_t bytes[STATUS_SIZE];
        self.encodeStatus(bytes);
        // Preserve brief failure/connecting transitions even when reconnect is
        // immediate. These are WiFiManager snapshots, not a second state machine.
        bytes[1] = stateByte(notice.state);
        bytes[2] = (bytes[2] & ~FLAG_STORED) | (notice.stored ? FLAG_STORED : 0);
        std::memcpy(bytes + 4, notice.ipv4, sizeof(notice.ipv4));
        if (!self.notify(self.status_handle_, self.status_subscribed_, bytes, sizeof(bytes)))
            self.last_error_ = INTERNAL_ERROR;
    }
    if (self.status_resync_.exchange(false)) self.notifyStatus();
    if (uxQueueMessagesWaiting(self.status_queue_))
        ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &self.status_event_);
}

void WiFiProvisioning::notifyNetworkInfo(const WiFiScanResult& network, const std::uint8_t ipv4[4])
{
    // Snapshot contains SSID/RSSI only, never password or NVS credential copies.
    const unsigned length = strnlen(network.ssid, sizeof(network.ssid));
    if (!data_subscribed_ || !length || length > MAX_SSID_SIZE ||
        !validCredentialUtf8(reinterpret_cast<const std::uint8_t*>(network.ssid), length)) return;
    std::uint8_t object[MAX_NETWORK_INFO_SIZE]{};
    object[0] = length;
    std::memcpy(object + 1, network.ssid, length);
    std::memcpy(object + 1 + length, ipv4, 4);
    object[5 + length] = static_cast<std::uint8_t>(network.rssi);
    const unsigned total = length + 6;
    for (unsigned offset = 0; offset < total; offset += CHUNK_SIZE) {
        std::uint8_t bytes[NOTIFICATION_SIZE];
        const auto size = encodeFragment(bytes, 0, 0, object, total, offset, NETWORK_INFO);
        if (!notify(data_handle_, data_subscribed_, bytes, size)) {
            last_error_ = INTERNAL_ERROR;
            break; // At most three bounded notifications; no host retry/wait loop.
        }
    }
}
