#pragma once
#include "provisioning_protocol.hpp"

namespace provisioning_protocol {
inline constexpr unsigned MAX_PASSWORD_SIZE = 63;
inline constexpr unsigned MAX_CREDENTIAL_SIZE = 2 + MAX_SSID_SIZE + MAX_PASSWORD_SIZE;
inline constexpr std::uint32_t CREDENTIAL_TIMEOUT_MS = 60000;

// Pure, hardware-independent reassembly. The owning BLE class uses secureZero
// when discarding this object; clear() also supports compile-time protocol tests.
struct CredentialStaging {
    std::uint8_t raw[MAX_CREDENTIAL_SIZE]{};
    std::uint8_t received[(MAX_CREDENTIAL_SIZE + 7) / 8]{};
    char ssid[MAX_SSID_SIZE + 1]{};
    char password[MAX_PASSWORD_SIZE + 1]{};
    unsigned total{}, count{};
    std::uint8_t transaction{};
    bool active{}, complete{};
    std::uint32_t last_activity{};

    constexpr void clear()
    {
        for (auto& byte : raw) byte = 0;
        for (auto& byte : received) byte = 0;
        for (auto& byte : ssid) byte = 0;
        for (auto& byte : password) byte = 0;
        total = count = transaction = last_activity = 0;
        active = complete = false;
    }
    constexpr void begin(std::uint8_t id, std::uint32_t now)
    {
        clear(); transaction = id; active = true; last_activity = now;
    }
    constexpr bool expired(std::uint32_t now) const
    {
        return active && static_cast<std::uint32_t>(now - last_activity) >= CREDENTIAL_TIMEOUT_MS;
    }
    constexpr bool expire(std::uint32_t now)
    {
        if (!expired(now)) return false;
        clear(); return true;
    }
    constexpr std::uint8_t checkTransaction(std::uint8_t id) const
    {
        if (!active) return NO_STAGED_CREDENTIALS;
        return id == transaction ? OK : TRANSACTION_MISMATCH;
    }
    constexpr std::uint8_t commit(std::uint8_t id) const
    {
        const auto error = checkTransaction(id);
        return error != OK ? error : complete ? OK : NO_STAGED_CREDENTIALS;
    }
    constexpr std::uint8_t cancel(std::uint8_t id)
    {
        const auto error = checkTransaction(id);
        if (error == OK) clear();
        return error;
    }
    constexpr std::uint8_t accept(const std::uint8_t* bytes, unsigned length, std::uint32_t now)
    {
        if (length < DATA_HEADER_SIZE) return FRAGMENT_ERROR;
        if (bytes[0] != VERSION) return UNSUPPORTED_VERSION;
        if (bytes[1] != WIFI_CREDENTIALS) return INVALID_COMMAND;
        const auto error = checkTransaction(bytes[2]);
        if (error != OK) return error;
        const unsigned offset = bytes[4], size = bytes[5], chunk = bytes[6];
        if (bytes[3] != 0 || size < 2 || size > MAX_CREDENTIAL_SIZE ||
            (total && size != total) || !chunk || length != DATA_HEADER_SIZE + chunk ||
            offset >= size || chunk > size - offset) return FRAGMENT_ERROR;
        // Check all overlaps before copying anything: identical duplicates are
        // harmless; conflicting overlap cannot partially corrupt a valid object.
        for (unsigned i = 0; i < chunk; ++i) {
            const unsigned at = offset + i;
            if ((received[at / 8] & (1u << (at % 8))) && raw[at] != bytes[7 + i])
                return FRAGMENT_ERROR;
        }
        total = size;
        for (unsigned i = 0; i < chunk; ++i) {
            const unsigned at = offset + i;
            if (!(received[at / 8] & (1u << (at % 8)))) {
                raw[at] = bytes[7 + i];
                received[at / 8] |= 1u << (at % 8);
                ++count;
            }
        }
        last_activity = now;
        if (count != total) return OK;
        const unsigned ssid_length = raw[0], password_length = raw[1];
        if (!ssid_length || ssid_length > MAX_SSID_SIZE) return INVALID_SSID;
        if (password_length > MAX_PASSWORD_SIZE || total != 2 + ssid_length + password_length ||
            (password_length != 0 && password_length < 8)) return INVALID_PASSWORD;
        // NVS uses C strings: embedded NULs must not silently truncate credentials.
        for (unsigned i = 0; i < ssid_length; ++i) if (raw[2 + i] == 0) return INVALID_SSID;
        for (unsigned i = 0; i < password_length; ++i)
            if (raw[2 + ssid_length + i] == 0) return INVALID_PASSWORD;
        for (unsigned i = 0; i < ssid_length; ++i) ssid[i] = raw[2 + i];
        for (unsigned i = 0; i < password_length; ++i) password[i] = raw[2 + ssid_length + i];
        ssid[ssid_length] = password[password_length] = 0;
        complete = true;
        return OK;
    }
};
} // namespace provisioning_protocol
