#include "ble_manager.hpp"
#include "ble_config.hpp"

#include <cstring>
#include "esp_log.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_att.h"
#include "host/ble_hs.h"
#include "host/ble_hs_mbuf.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

namespace {
constexpr char TAG[] = "ble_manager";
constexpr std::uint16_t NO_CONNECTION = 0xffff;
void writeBe(std::uint8_t* out, std::uint64_t value, unsigned bytes) {
    for (unsigned i = 0; i < bytes; ++i)
        out[i] = static_cast<std::uint8_t>(value >> (8 * (bytes - i - 1)));
}
}

BLEManager* BLEManager::instance_ = nullptr;

bool BLEManager::init()
{
    if (initialized_) return true;
    if (instance_) return false;
    // Wi-Fi normally initialized NVS first; never erase shared NVS here.
    if (nvs_flash_init() != ESP_OK) {
        ESP_LOGE(TAG, "NVS unavailable for NimBLE");
        return false;
    }
    const esp_err_t error = nimble_port_init();
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "NimBLE init failed: %s", esp_err_to_name(error));
        return false;
    }
    instance_ = this;
    ble_hs_cfg.sync_cb = onSync;
    ble_hs_cfg.reset_cb = onReset;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    if (ble_svc_gap_device_name_set(ble_config::DEVICE_NAME) != 0 ||
        ble_att_set_preferred_mtu(ble_config::PREFERRED_ATT_MTU) != 0) {
        ESP_LOGE(TAG, "BLE name or preferred MTU setup failed");
        nimble_port_deinit();
        instance_ = nullptr;
        return false;
    }

    // NimBLE retains the definitions; static arrays have firmware lifetime.
    static ble_gatt_chr_def chars[5]{};
    const ble_uuid_t* uuids[] = {&ble_config::VOLTAGE_UUID.u, &ble_config::STATUS_UUID.u,
                                  &ble_config::CONFIG_UUID.u, &ble_config::COMMAND_UUID.u};
    const ble_gatt_chr_flags flags[] = {
        BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
        BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
        BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE,
        BLE_GATT_CHR_F_WRITE};
    for (unsigned i = 0; i < 4; ++i) {
        chars[i].uuid = uuids[i];
        chars[i].access_cb = access;
        chars[i].arg = this;
        chars[i].flags = flags[i];
    }
    chars[0].val_handle = &voltage_handle_;
    chars[1].val_handle = &status_handle_;
    static ble_gatt_svc_def services[2]{};
    services[0].type = BLE_GATT_SVC_TYPE_PRIMARY;
    services[0].uuid = &ble_config::SERVICE_UUID.u;
    services[0].characteristics = chars;
    const int count_rc = ble_gatts_count_cfg(services);
    const int add_rc = count_rc == 0 ? ble_gatts_add_svcs(services) : count_rc;
    if (add_rc != 0) {
        ESP_LOGE(TAG, "GATT registration failed: %d", add_rc);
        nimble_port_deinit();
        instance_ = nullptr;
        return false;
    }
    initialized_ = true;
    return true;
}

bool BLEManager::start()
{
    if (!initialized_) return false;
    if (started_) return true;
    // NimBLE owns its host task. This separate static task only samples at 10 Hz.
    nimble_port_freertos_init(hostTask);
    if (!xTaskCreateStatic(updateTask, "ble_update", STACK_BYTES, this, 2,
                           stack_, &task_control_)) {
        ESP_LOGE(TAG, "BLE update task creation failed");
        return false;
    }
    started_ = true;
    return true;
}

void BLEManager::hostTask(void*)
{
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void BLEManager::onSync()
{
    if (!instance_) return;
    if (ble_hs_util_ensure_addr(0) != 0 ||
        ble_hs_id_infer_auto(0, &instance_->address_type_) != 0) {
        ESP_LOGE(TAG, "BLE address unavailable");
        return;
    }
    instance_->advertise();
}

void BLEManager::onReset(int reason)
{
    ESP_LOGW(TAG, "NimBLE host reset: %d", reason);
}

void BLEManager::advertise()
{
    if (ble_gap_adv_active()) return;
    ble_hs_adv_fields fields{};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = const_cast<ble_uuid128_t*>(&ble_config::SERVICE_UUID);
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    ble_hs_adv_fields response{};
    response.name = reinterpret_cast<std::uint8_t*>(const_cast<char*>(ble_config::DEVICE_NAME));
    response.name_len = sizeof(ble_config::DEVICE_NAME) - 1;
    response.name_is_complete = 1;
    ble_gap_adv_params params{};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    const int fields_rc = ble_gap_adv_set_fields(&fields);
    const int response_rc = fields_rc == 0 ? ble_gap_adv_rsp_set_fields(&response) : fields_rc;
    const int start_rc = response_rc == 0 ? ble_gap_adv_start(address_type_, nullptr,
        BLE_HS_FOREVER, &params, gapEvent, this) : response_rc;
    if (start_rc != 0) ESP_LOGE(TAG, "BLE advertising failed: %d", start_rc);
    else ESP_LOGI(TAG, "Advertising %s", ble_config::DEVICE_NAME);
}

int BLEManager::gapEvent(ble_gap_event* event, void* arg)
{
    auto& self = *static_cast<BLEManager*>(arg);
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            self.have_read_voltage_ = false;
            self.connection_.store(event->connect.conn_handle);
            self.connected_.store(true);
            self.diagnostics_.recordBleConnection(true);
            ESP_LOGI(TAG, "Client connected");
        } else self.advertise();
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        self.have_read_voltage_ = false;
        self.connected_.store(false);
        self.connection_.store(NO_CONNECTION);
        self.voltage_subscribed_.store(false);
        self.status_subscribed_.store(false);
        self.diagnostics_.recordBleConnection(false);
        ESP_LOGI(TAG, "Client disconnected; advertising again");
        self.advertise();
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == self.voltage_handle_)
            self.voltage_subscribed_.store(event->subscribe.cur_notify != 0);
        if (event->subscribe.attr_handle == self.status_handle_)
            self.status_subscribed_.store(event->subscribe.cur_notify != 0);
        break;
    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "Negotiated ATT MTU=%u", event->mtu.value);
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        if (!self.connected_.load()) self.advertise();
        break;
    default: break;
    }
    return 0;
}

void BLEManager::encodeVoltage(const SampleFrame& frame, std::uint8_t out[80]) const
{
    writeBe(out, frame.sequence, 4);
    writeBe(out + 4, frame.timestamp_us, 8);
    for (unsigned i = 0; i < 16; ++i)
        writeBe(out + 12 + 4 * i, static_cast<std::uint32_t>(frame.channels[i]), 4);
    writeBe(out + 76, frame.status, 4);
}

void BLEManager::encodeStatus(std::uint8_t out[8]) const
{
    out[0] = 1; // status schema version
    out[1] = acquisition_running_.load() ? 1 : 0;
    out[2] = wifi_status_ && wifi_status_(wifi_context_) ? 1 : 0;
    out[3] = connected_.load() ? 1 : 0;
    SampleFrame frame{};
    writeBe(out + 4, latest_.read(frame) ? frame.status : 0, 4);
}

int BLEManager::access(uint16_t, uint16_t, ble_gatt_access_ctxt* ctxt, void* arg)
{
    auto& self = *static_cast<BLEManager*>(arg);
    const ble_uuid_t* uuid = ctxt->chr->uuid;
    if (ble_uuid_cmp(uuid, &ble_config::VOLTAGE_UUID.u) == 0 &&
        ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        // Hold one value across ATT read-blob requests at a small MTU.
        if (ctxt->offset == 0 || !self.have_read_voltage_) {
            SampleFrame frame{};
            if (!self.latest_.read(frame)) return BLE_ATT_ERR_UNLIKELY;
            self.encodeVoltage(frame, self.read_voltage_);
            self.have_read_voltage_ = true;
        }
        return os_mbuf_append(ctxt->om, self.read_voltage_, sizeof(self.read_voltage_)) == 0 ?
            0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (ble_uuid_cmp(uuid, &ble_config::STATUS_UUID.u) == 0 &&
        ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        std::uint8_t bytes[8];
        self.encodeStatus(bytes);
        return os_mbuf_append(ctxt->om, bytes, sizeof(bytes)) == 0 ?
            0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (ble_uuid_cmp(uuid, &ble_config::CONFIG_UUID.u) == 0) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR)
            return os_mbuf_append(ctxt->om, &self.config_value_, 1) == 0 ?
                0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
            std::uint8_t value = 0;
            if (OS_MBUF_PKTLEN(ctxt->om) != 1 ||
                ble_hs_mbuf_to_flat(ctxt->om, &value, 1, nullptr) != 0 || value > 1)
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            self.config_value_ = value; // Placeholder only; no hardware behavior.
            return 0;
        }
    }
    if (ble_uuid_cmp(uuid, &ble_config::COMMAND_UUID.u) == 0 &&
        ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        std::uint8_t value = 0xff;
        if (OS_MBUF_PKTLEN(ctxt->om) != 1 ||
            ble_hs_mbuf_to_flat(ctxt->om, &value, 1, nullptr) != 0 || value != 0)
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        return 0; // 0x00 is a no-op.
    }
    return BLE_ATT_ERR_UNLIKELY;
}

void BLEManager::updateTask(void* arg)
{
    auto& self = *static_cast<BLEManager*>(arg);
    TickType_t wake = xTaskGetTickCount();
    for (;;) {
        vTaskDelayUntil(&wake, pdMS_TO_TICKS(ble_config::UPDATE_PERIOD_MS));
        self.update();
    }
}

void BLEManager::update()
{
    if (!connected_.load()) return;
    const std::uint16_t connection = connection_.load();
    if (connection == NO_CONNECTION) return;
    if (voltage_subscribed_.load()) {
        // ATT notification value capacity is MTU-3; never truncate 80 bytes.
        if (ble_att_mtu(connection) >= 83) {
            SampleFrame frame{};
            if (latest_.read(frame)) {
                std::uint8_t bytes[80];
                encodeVoltage(frame, bytes);
                os_mbuf* value = ble_hs_mbuf_from_flat(bytes, sizeof(bytes));
                const bool accepted = value &&
                    ble_gatts_notify_custom(connection, voltage_handle_, value) == 0;
                diagnostics_.recordBleNotification(accepted);
            }
        }
    }
    if (status_subscribed_.load()) {
        std::uint8_t bytes[8];
        encodeStatus(bytes);
        os_mbuf* value = ble_hs_mbuf_from_flat(bytes, sizeof(bytes));
        const bool accepted = value &&
            ble_gatts_notify_custom(connection, status_handle_, value) == 0;
        diagnostics_.recordBleNotification(accepted);
    }
}
