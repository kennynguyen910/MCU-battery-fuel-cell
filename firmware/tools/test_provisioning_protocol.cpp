// Compile-only tests exercise the actual constexpr protocol helpers.
// Run with an ESP-IDF C++ compiler: -std=c++17 -fsyntax-only
// -Icomponents/ble/include tools/test_provisioning_protocol.cpp
#include "provisioning_protocol.hpp"
#include "credential_staging.hpp"
#include <initializer_list>
using namespace provisioning_protocol;

constexpr bool commandTests()
{
    if (validateControl(nullptr, 0) != INVALID_PAYLOAD) return false;
    std::uint8_t request[] = {1, GET_STATUS, 1, 0};
    for (unsigned length = 0; length < 4; ++length)
        if (validateControl(request, length) != INVALID_PAYLOAD) return false;
    for (unsigned opcode : {GET_STATUS, START_SCAN, BEGIN_CREDENTIALS, COMMIT_CREDENTIALS, CLEAR_CREDENTIALS, CANCEL}) {
        request[1] = opcode;
        for (unsigned transaction = 1; transaction <= 255; ++transaction) {
            request[2] = transaction;
            if (validateControl(request, 4) != OK) return false;
        }
    }
    request[2] = 0;
    if (validateControl(request, 4) != INVALID_PAYLOAD) return false;
    request[2] = 1;
    request[0] = 2;
    if (validateControl(request, 4) != UNSUPPORTED_VERSION) return false;
    request[0] = 1;
    request[1] = 7; // Unknown opcodes must not be accepted.
    if (validateControl(request, 4) != INVALID_COMMAND) return false;
    request[1] = START_SCAN;
    request[3] = 1;
    if (validateControl(request, 4) != INVALID_PAYLOAD) return false;
    request[3] = 0;
    return validateControl(request, 5) == INVALID_PAYLOAD &&
           validateControl(request, 512) == INVALID_PAYLOAD;
}

constexpr bool fragmentTests()
{
    std::uint8_t object[MAX_OBJECT_SIZE]{};
    for (unsigned i = 0; i < MAX_OBJECT_SIZE; ++i) object[i] = i + 1;
    // All supported SSID lengths, including the maximum 36-byte logical object.
    for (unsigned total = OBJECT_HEADER_SIZE + 1; total <= MAX_OBJECT_SIZE; ++total) {
        unsigned offset = 0;
        unsigned fragments = 0;
        while (offset < total) {
            std::uint8_t bytes[NOTIFICATION_SIZE]{};
            const auto length = encodeFragment(bytes, 0x17, 14, object, total, offset);
            if (length > 20 || length <= 7 || bytes[0] != 1 || bytes[1] != 2 ||
                bytes[2] != 0x17 || bytes[3] != 14 || bytes[4] != offset ||
                bytes[5] != total || bytes[6] != length - 7) return false;
            for (unsigned j = 0; j < bytes[6]; ++j)
                if (bytes[7 + j] != object[offset + j]) return false;
            offset += bytes[6];
            if (++fragments > 3) return false;
        }
        if (offset != total) return false;
    }
    std::uint8_t bytes[NOTIFICATION_SIZE]{};
    return encodeFragment(bytes, 1, 0, object, 37, 0) == 0 &&
           encodeFragment(bytes, 1, 0, object, 36, 36) == 0 &&
           encodeFragment(bytes, 1, 0, object, 0, 0) == 0;
}
static_assert(STATUS_SIZE == 8);
static_assert(CHUNK_SIZE == 13);
static_assert(commandTests(), "Malformed control command regression");
static_assert(fragmentTests(), "Default-MTU fragmentation regression");


constexpr std::uint8_t feed(CredentialStaging& stage, const std::uint8_t* object,
                            unsigned total, unsigned offset, unsigned chunk,
                            std::uint8_t transaction = 0x10, std::uint32_t now = 10)
{
    std::uint8_t packet[DATA_HEADER_SIZE + MAX_CREDENTIAL_SIZE]{};
    packet[0] = VERSION; packet[1] = WIFI_CREDENTIALS; packet[2] = transaction;
    packet[3] = 0; packet[4] = offset; packet[5] = total; packet[6] = chunk;
    for (unsigned i = 0; i < chunk; ++i) packet[7 + i] = object[offset + i];
    return stage.accept(packet, 7 + chunk, now);
}

constexpr bool erased(const CredentialStaging& stage)
{
    for (auto byte : stage.raw) if (byte) return false;
    for (auto byte : stage.received) if (byte) return false;
    for (auto byte : stage.ssid) if (byte) return false;
    for (auto byte : stage.password) if (byte) return false;
    return !stage.active && !stage.complete && !stage.total && !stage.count &&
           !stage.transaction && !stage.last_activity;
}

constexpr bool credentialTests()
{
    // Fictional test bytes only: 8-byte SSID and 10-byte password.
    std::uint8_t object[MAX_CREDENTIAL_SIZE] = {8, 10};
    for (unsigned i = 2; i < 20; ++i) object[i] = 'a' + i;
    CredentialStaging stage;
    stage.begin(0x10, 0);
    if (feed(stage, object, 20, 0, 20) != OK || stage.commit(0x10) != OK ||
        stage.ssid[8] != 0 || stage.password[10] != 0) return false;
    // Out-of-order fragments, duplicate bytes, and incomplete COMMIT.
    stage.begin(0x10, 0);
    if (feed(stage, object, 20, 13, 7) != OK || stage.commit(0x10) != NO_STAGED_CREDENTIALS) return false;
    if (feed(stage, object, 20, 13, 7) != OK || stage.count != 7) return false;
    if (feed(stage, object, 20, 0, 13) != OK || stage.commit(0x10) != OK) return false;
    if (feed(stage, object, 20, 0, 13) != OK || stage.count != 20 || stage.commit(0x11) != TRANSACTION_MISMATCH)
        return false;
    object[13] ^= 1;
    if (feed(stage, object, 20, 12, 8) != FRAGMENT_ERROR || stage.raw[13] == object[13]) return false;
    object[13] ^= 1;
    if (feed(stage, object, 20, 0, 13, 0x11) != TRANSACTION_MISMATCH) return false;
    if (stage.cancel(0x11) != TRANSACTION_MISMATCH || !stage.complete) return false;
    if (stage.cancel(0x10) != OK || !erased(stage) || stage.commit(0x10) != NO_STAGED_CREDENTIALS) return false;
    // Both maximum lengths, fragmented with a hole that must prevent COMMIT.
    object[0] = 32; object[1] = 63;
    for (unsigned i = 2; i < 97; ++i) object[i] = 'x';
    stage.begin(0x10, 0);
    if (feed(stage, object, 97, 1, 96) != OK || stage.commit(0x10) != NO_STAGED_CREDENTIALS) return false;
    if (feed(stage, object, 97, 0, 1) != OK || stage.commit(0x10) != OK ||
        stage.ssid[32] || stage.password[63]) return false;
    // Open network is valid; SSID must not be empty.
    object[0] = 1; object[1] = 0; object[2] = 'A';
    stage.begin(0x10, 0);
    if (feed(stage, object, 3, 0, 3) != OK || stage.password[0] || stage.commit(0x10) != OK) return false;
    object[0] = 0;
    stage.begin(0x10, 0);
    if (feed(stage, object, 2, 0, 2) != INVALID_SSID) return false;
    object[0] = 1;
    stage.begin(0x10, 0);
    if (feed(stage, object, 4, 0, 4) != INVALID_PASSWORD) return false; // Declared object length mismatch.
    object[2] = 0;
    stage.begin(0x10, 0);
    if (feed(stage, object, 3, 0, 3) != INVALID_SSID) return false; // Embedded NUL.
    object[2] = 'A'; object[1] = 7;
    stage.begin(0x10, 0);
    if (feed(stage, object, 10, 0, 10) != INVALID_PASSWORD) return false;
    object[1] = 8; object[3] = 0;
    stage.begin(0x10, 0);
    if (feed(stage, object, 11, 0, 11) != INVALID_PASSWORD) return false;
    // Total consistency, boundaries, declared chunk length, type, ID, and version.
    std::uint8_t packet[] = {1, 1, 0x10, 0, 0, 20, 1, 8};
    stage.begin(0x10, 0);
    if (stage.accept(packet, 8, 10) != OK) return false;
    packet[5] = 21;
    if (stage.accept(packet, 8, 10) != FRAGMENT_ERROR || stage.total != 20) return false;
    packet[5] = 20; packet[4] = 20;
    if (stage.accept(packet, 8, 10) != FRAGMENT_ERROR) return false;
    packet[4] = 19; packet[6] = 2;
    if (stage.accept(packet, 9, 10) != FRAGMENT_ERROR) return false; // Rejected before reading chunk.
    packet[4] = 0;
    if (stage.accept(packet, 8, 10) != FRAGMENT_ERROR) return false;
    packet[6] = 0;
    if (stage.accept(packet, 7, 10) != FRAGMENT_ERROR) return false;
    packet[6] = 1; packet[3] = 1;
    if (stage.accept(packet, 8, 10) != FRAGMENT_ERROR) return false;
    packet[3] = 0; packet[0] = 2;
    if (stage.accept(packet, 8, 10) != UNSUPPORTED_VERSION) return false;
    packet[0] = 1; packet[1] = 2;
    if (stage.accept(packet, 8, 10) != INVALID_COMMAND) return false;
    packet[1] = 1; packet[5] = 98;
    if (stage.accept(packet, 8, 10) != FRAGMENT_ERROR) return false;
    if (stage.accept(nullptr, 0, 10) != FRAGMENT_ERROR) return false;
    // Rolling timeout and wraparound, including wiping a partial password.
    stage.begin(0x10, 0xfffffff0u);
    object[0] = 1; object[1] = 8; object[3] = 'p';
    if (feed(stage, object, 11, 3, 1, 0x10, 0xfffffff0u) != OK) return false;
    if (stage.expire(0xfffffff0u + 59999u) || !stage.expire(0xfffffff0u + 60000u) || !erased(stage)) return false;
    return true;
}
static_assert(credentialTests(), "Credential reassembly/validation/cleanup regression");
