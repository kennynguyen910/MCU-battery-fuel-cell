#include "wifi_provisioning.hpp"

#include <cstring>
#include "esp_log.h"
#include "esp_wifi.h"
#include "host/ble_hs.h"
#include "host/ble_hs_mbuf.h"
#include "nimble/nimble_port.h"

namespace {
using namespace provisioning_protocol;
constexpr const char* TAG = "wifi_provisioning";
// UUID byte order follows NimBLE (least significant byte first).
const ble_uuid128_t SERVICE_UUID = BLE_UUID128_INIT(
    0xd0,0x21,0x60,0x40,0x0f,0x64,0x96,0x9c,0xc4,0x4c,0xc2,0x41,0x00,0x10,0xcf,0x5e);
const ble_uuid128_t CONTROL_UUID = BLE_UUID128_INIT(
    0xd0,0x21,0x60,0x40,0x0f,0x64,0x96,0x9c,0xc4,0x4c,0xc2,0x41,0x01,0x10,0xcf,0x5e);
const ble_uuid128_t DATA_UUID = BLE_UUID128_INIT(
    0xd0,0x21,0x60,0x40,0x0f,0x64,0x96,0x9c,0xc4,0x4c,0xc2,0x41,0x02,0x10,0xcf,0x5e);
const ble_uuid128_t STATUS_UUID = BLE_UUID128_INIT(
    0xd0,0x21,0x60,0x40,0x0f,0x64,0x96,0x9c,0xc4,0x4c,0xc2,0x41,0x03,0x10,0xcf,0x5e);

std::uint8_t authType(std::uint8_t mode)
{
    switch (mode) {
    case WIFI_AUTH_OPEN: return 0x00;
    case WIFI_AUTH_WEP: return 0x01;
    case WIFI_AUTH_WPA_PSK: return 0x02;
    case WIFI_AUTH_WPA2_PSK: return 0x03;
    case WIFI_AUTH_WPA_WPA2_PSK: return 0x04;
    case WIFI_AUTH_WPA3_PSK:
    case WIFI_AUTH_WPA3_EXT_PSK:
    case WIFI_AUTH_WPA3_EXT_PSK_MIXED_MODE: return 0x05;
    case WIFI_AUTH_WPA2_WPA3_PSK: return 0x06;
    case WIFI_AUTH_ENTERPRISE:
    case WIFI_AUTH_WPA3_ENT_192:
    case WIFI_AUTH_WPA3_ENTERPRISE:
    case WIFI_AUTH_WPA2_WPA3_ENTERPRISE:
    case WIFI_AUTH_WPA_ENTERPRISE: return 0x07;
    default: return 0xff;
    }
}
}

void WiFiProvisioning::configureService(ble_gatt_svc_def& service)
{
    const ble_uuid_t* uuids[] = {&CONTROL_UUID.u, &DATA_UUID.u, &STATUS_UUID.u};
    std::uint16_t* handles[] = {&control_handle_, &data_handle_, &status_handle_};
    for (unsigned i = 0; i < 3; ++i) {
        auto& characteristic = characteristics_[i];
        characteristic.uuid = uuids[i];
        characteristic.access_cb = access;
        characteristic.arg = this;
        characteristic.val_handle = handles[i];
        characteristic.flags = BLE_GATT_CHR_F_NOTIFY |
            (i == 2 ? BLE_GATT_CHR_F_READ : BLE_GATT_CHR_F_WRITE);
    }
    service.type = BLE_GATT_SVC_TYPE_PRIMARY;
    service.uuid = &SERVICE_UUID.u;
    service.characteristics = characteristics_;
}

bool WiFiProvisioning::start()
{
    if (task_) return true;
    ble_npl_event_init(&ready_event_, scanReady, this);
    if (ble_npl_callout_init(&send_callout_, nimble_port_get_dflt_eventq(), sendNext, this) != 0)
        return false;
    callout_initialized_ = true;
    task_ = xTaskCreateStatic(worker, "wifi_provision", STACK_BYTES, this, 2, stack_, &task_storage_);
    return task_ != nullptr;
}

void WiFiProvisioning::reset()
{
    ++session_; // Invalidate old work even if a connection handle is reused.
    connection_ = BLE_HS_CONN_HANDLE_NONE;
    control_subscribed_ = data_subscribed_ = status_subscribed_ = false;
    if (callout_initialized_) ble_npl_callout_stop(&send_callout_);
    if (delivering_) {
        delivering_ = false;
        busy_ = false;
    }
    // A worker still scanning owns results_ until scanReady; let it finish and
    // discard there. Disconnect never waits for the scan or touches acquisition.
}

void WiFiProvisioning::gapEvent(const ble_gap_event& event)
{
    if (event.type == BLE_GAP_EVENT_CONNECT && event.connect.status == 0) {
        reset();
        connection_ = event.connect.conn_handle;
        last_error_ = OK;
    } else if (event.type == BLE_GAP_EVENT_DISCONNECT) {
        reset();
    } else if (event.type == BLE_GAP_EVENT_SUBSCRIBE) {
        const bool subscribed = event.subscribe.cur_notify != 0;
        if (event.subscribe.attr_handle == control_handle_) control_subscribed_ = subscribed;
        if (event.subscribe.attr_handle == data_handle_) data_subscribed_ = subscribed;
        if (event.subscribe.attr_handle == status_handle_) status_subscribed_ = subscribed;
    }
}

void WiFiProvisioning::encodeStatus(std::uint8_t (&out)[STATUS_SIZE])
{
    std::memset(out, 0, sizeof(out));
    out[0] = VERSION;
    switch (wifi_.getState()) {
    case WiFiState::UNPROVISIONED: out[1] = 0x00; break;
    case WiFiState::CONNECTING: out[1] = 0x01; break;
    case WiFiState::CONNECTED: out[1] = 0x02; break;
    case WiFiState::CONNECTION_FAILED: out[1] = 0x03; break;
    }
    if (wifi_.credentialsStored()) out[2] |= FLAG_STORED;
    if (scanning_.load()) out[2] |= FLAG_SCANNING;
    ble_gap_conn_desc connection{};
    if (connection_ != BLE_HS_CONN_HANDLE_NONE &&
        ble_gap_conn_find(connection_, &connection) == 0 && connection.sec_state.encrypted)
        out[2] |= FLAG_ENCRYPTED;
    out[3] = last_error_;
    if (out[1] == 0x02) wifi_.getIPv4(out + 4);
}

bool WiFiProvisioning::notify(std::uint16_t handle, bool subscribed,
                              const std::uint8_t* data, unsigned length)
{
    if (!subscribed || connection_ == BLE_HS_CONN_HANDLE_NONE) return false;
    os_mbuf* value = ble_hs_mbuf_from_flat(data, length);
    // notify_custom consumes the mbuf even on failure. All sends occur on the
    // host task, so disconnect/reconnect cannot interleave session validation.
    return value && ble_gatts_notify_custom(connection_, handle, value) == 0;
}

void WiFiProvisioning::notifyStatus()
{
    if (!status_subscribed_) return;
    std::uint8_t bytes[STATUS_SIZE];
    encodeStatus(bytes);
    if (!notify(status_handle_, status_subscribed_, bytes, sizeof(bytes))) {
        last_error_ = INTERNAL_ERROR;
        ESP_LOGW(TAG, "Status notification failed");
    }
}

bool WiFiProvisioning::response(std::uint8_t opcode, std::uint8_t transaction,
                                std::uint8_t command, std::uint8_t result)
{
    const std::uint8_t bytes[] = {VERSION, opcode, transaction, 2, command, result};
    return notify(control_handle_, control_subscribed_, bytes, sizeof(bytes));
}

void WiFiProvisioning::fail(std::uint8_t transaction, std::uint8_t command, std::uint8_t error)
{
    last_error_ = error;
    if (!response(ERROR, transaction, command, error))
        ESP_LOGW(TAG, "Provisioning error response unavailable");
}

int WiFiProvisioning::access(std::uint16_t, std::uint16_t handle,
                             ble_gatt_access_ctxt* ctxt, void* arg)
{
    auto& self = *static_cast<WiFiProvisioning*>(arg);
    if (handle == self.status_handle_ && ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        std::uint8_t bytes[STATUS_SIZE];
        self.encodeStatus(bytes);
        return os_mbuf_append(ctxt->om, bytes, sizeof(bytes)) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (handle == self.data_handle_) {
        self.last_error_ = INVALID_COMMAND;
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED; // Credentials are not implemented.
    }
    if (handle != self.control_handle_ || ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR)
        return BLE_ATT_ERR_UNLIKELY;
    const unsigned length = OS_MBUF_PKTLEN(ctxt->om);
    std::uint8_t header[CONTROL_HEADER_SIZE]{};
    const unsigned prefix = length < sizeof(header) ? length : sizeof(header);
    if (prefix && os_mbuf_copydata(ctxt->om, 0, prefix, header) != 0)
        return BLE_ATT_ERR_UNLIKELY;
    const auto error = validateControl(header, length);
    if (error != OK) {
        self.fail(header[2], header[1], error);
        return 0;
    }
    // A write cannot be accepted without a way to send the protocol ACK.
    if (!self.control_subscribed_) {
        self.last_error_ = INTERNAL_ERROR;
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (header[1] == GET_STATUS) {
        self.last_error_ = OK;
        if (!self.response(ACK, header[2], GET_STATUS, OK)) {
            self.last_error_ = INTERNAL_ERROR;
            return BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        self.notifyStatus();
        return 0;
    }
    if (self.busy_) {
        self.fail(header[2], START_SCAN, OPERATION_BUSY);
        return 0;
    }
    if (!self.task_) {
        self.fail(header[2], START_SCAN, INTERNAL_ERROR);
        return 0;
    }
    self.last_error_ = OK;
    if (!self.response(ACK, header[2], START_SCAN, OK)) {
        self.last_error_ = INTERNAL_ERROR;
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    self.busy_ = true;
    self.scanning_.store(true);
    self.transaction_ = header[2];
    self.request_session_ = self.session_;
    self.notifyStatus();
    xTaskNotifyGive(self.task_);
    return 0;
}

void WiFiProvisioning::worker(void* arg)
{
    auto& self = *static_cast<WiFiProvisioning*>(arg);
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        self.scan_error_ = self.wifi_.scanNetworks(self.results_, self.result_count_, self.found_);
        self.scanning_.store(false);
        ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &self.ready_event_);
    }
}

void WiFiProvisioning::scanReady(ble_npl_event* event)
{
    auto& self = *static_cast<WiFiProvisioning*>(ble_npl_event_get_arg(event));
    if (self.request_session_ != self.session_ || self.connection_ == BLE_HS_CONN_HANDLE_NONE) {
        self.busy_ = false;
        return;
    }
    self.reported_ = self.result_index_ = self.offset_ = 0;
    self.notifyStatus();
    if (self.scan_error_ != ESP_OK) {
        self.fail(self.transaction_, START_SCAN,
            self.scan_error_ == ESP_ERR_WIFI_STATE ? OPERATION_BUSY : SCAN_FAILED);
        self.busy_ = false;
        self.notifyStatus();
        return;
    }
    self.delivering_ = true;
    if (!self.data_subscribed_ && self.result_count_ != 0) {
        ESP_LOGW(TAG, "Scan results unavailable: Data notifications not subscribed");
        self.fail(self.transaction_, START_SCAN, INTERNAL_ERROR);
        self.finish();
        return;
    }
    self.nextFragment();
}

void WiFiProvisioning::sendNext(ble_npl_event* event)
{
    static_cast<WiFiProvisioning*>(ble_npl_event_get_arg(event))->nextFragment();
}

void WiFiProvisioning::nextFragment()
{
    if (!delivering_) return;
    if (request_session_ != session_ || connection_ == BLE_HS_CONN_HANDLE_NONE) {
        delivering_ = busy_ = false;
        return;
    }
    if (result_index_ >= result_count_) {
        finish();
        return;
    }
    const auto& result = results_[result_index_];
    const unsigned ssid_length = std::strlen(result.ssid);
    std::uint8_t object[MAX_OBJECT_SIZE]{};
    object[0] = result_index_;
    object[1] = static_cast<std::uint8_t>(result.rssi);
    object[2] = authType(result.auth);
    object[3] = ssid_length;
    std::memcpy(object + OBJECT_HEADER_SIZE, result.ssid, ssid_length);
    std::uint8_t bytes[NOTIFICATION_SIZE];
    const unsigned length = encodeFragment(bytes, transaction_, result_index_, object,
                                            OBJECT_HEADER_SIZE + ssid_length, offset_);
    if (!length || !notify(data_handle_, data_subscribed_, bytes, length)) {
        ESP_LOGW(TAG, "Provisioning scan notification failed");
        fail(transaction_, START_SCAN, INTERNAL_ERROR);
        finish(); // No retry loop; only fully enqueued objects count as reported.
        return;
    }
    offset_ += bytes[6];
    if (offset_ == OBJECT_HEADER_SIZE + ssid_length) {
        ++reported_;
        ++result_index_;
        offset_ = 0;
    }
    // One small fragment per callout; no sleeping or scan work on the host task.
    if (ble_npl_callout_reset(&send_callout_, ble_npl_time_ms_to_ticks32(20)) != 0) {
        fail(transaction_, START_SCAN, INTERNAL_ERROR);
        finish();
    }
}

void WiFiProvisioning::finish()
{
    const std::uint8_t bytes[] = {VERSION, SCAN_COMPLETE, transaction_, 1, reported_};
    if (!notify(control_handle_, control_subscribed_, bytes, sizeof(bytes))) {
        last_error_ = INTERNAL_ERROR;
        ESP_LOGW(TAG, "SCAN_COMPLETE notification failed");
    }
    ESP_LOGI(TAG, "Wi-Fi scan complete: %u APs found, %u reported", found_, reported_);
    delivering_ = busy_ = false;
    notifyStatus();
}
