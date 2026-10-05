#pragma once

#include <cstddef>
#include <cstdint>

namespace provisioning_protocol {
inline constexpr std::uint8_t VERSION = 0x01;
inline constexpr std::uint8_t GET_STATUS = 0x01, START_SCAN = 0x02,
    BEGIN_CREDENTIALS = 0x03, COMMIT_CREDENTIALS = 0x04, CLEAR_CREDENTIALS = 0x05, CANCEL = 0x06;
inline constexpr std::uint8_t ACK = 0x80, ERROR = 0x81, SCAN_COMPLETE = 0x82;
inline constexpr std::uint8_t WIFI_CREDENTIALS = 0x01, SCAN_RESULT = 0x02;
inline constexpr std::uint8_t OK = 0x00, UNSUPPORTED_VERSION = 0x01,
    INVALID_COMMAND = 0x02, INVALID_PAYLOAD = 0x03, OPERATION_BUSY = 0x04,
    SECURITY_REQUIRED = 0x05, SCAN_FAILED = 0x06, INVALID_SSID = 0x07,
    INVALID_PASSWORD = 0x08, NVS_SAVE_FAILED = 0x09, WIFI_CONNECTION_FAILED = 0x0a,
    TIMEOUT = 0x0b, NO_STAGED_CREDENTIALS = 0x0c, TRANSACTION_MISMATCH = 0x0d,
    FRAGMENT_ERROR = 0x0e, INTERNAL_ERROR = 0x0f;
inline constexpr unsigned STATUS_SIZE = 8, CONTROL_HEADER_SIZE = 4;
inline constexpr unsigned DATA_HEADER_SIZE = 7, NOTIFICATION_SIZE = 20;
inline constexpr unsigned CHUNK_SIZE = NOTIFICATION_SIZE - DATA_HEADER_SIZE;
inline constexpr unsigned MAX_SSID_SIZE = 32, OBJECT_HEADER_SIZE = 4;
inline constexpr unsigned MAX_OBJECT_SIZE = OBJECT_HEADER_SIZE + MAX_SSID_SIZE;
inline constexpr std::uint8_t FLAG_STORED = 1, FLAG_SCANNING = 2, FLAG_TRANSACTION = 4, FLAG_ENCRYPTED = 8;

// Pure bounded validation; caller may pass a copied four-byte prefix with the
// original total length. Never reads beyond that prefix or a short request.
constexpr std::uint8_t validateControl(const std::uint8_t* bytes, std::size_t length)
{
    if (length < CONTROL_HEADER_SIZE) return INVALID_PAYLOAD;
    if (bytes[0] != VERSION) return UNSUPPORTED_VERSION;
    if (length != CONTROL_HEADER_SIZE || bytes[3] != 0 || bytes[2] == 0) return INVALID_PAYLOAD;
    if (bytes[1] < GET_STATUS || bytes[1] > CANCEL) return INVALID_COMMAND;
    return OK;
}

constexpr unsigned encodeFragment(std::uint8_t* out, std::uint8_t transaction,
                                  std::uint8_t object_id, const std::uint8_t* object,
                                  unsigned total, unsigned offset)
{
    if (total > MAX_OBJECT_SIZE || offset >= total) return 0;
    const unsigned count = total - offset < CHUNK_SIZE ? total - offset : CHUNK_SIZE;
    out[0] = VERSION; out[1] = SCAN_RESULT; out[2] = transaction;
    out[3] = object_id; out[4] = offset; out[5] = total; out[6] = count;
    for (unsigned i = 0; i < count; ++i) out[DATA_HEADER_SIZE + i] = object[offset + i];
    return DATA_HEADER_SIZE + count;
}
} // namespace provisioning_protocol
