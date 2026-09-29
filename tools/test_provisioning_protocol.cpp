// Compile-only tests exercise the actual constexpr protocol helpers.
// Run with an ESP-IDF C++ compiler: -std=c++17 -fsyntax-only
// -Icomponents/ble/include tools/test_provisioning_protocol.cpp
#include "provisioning_protocol.hpp"
#include <initializer_list>
using namespace provisioning_protocol;

constexpr bool commandTests()
{
    if (validateControl(nullptr, 0) != INVALID_PAYLOAD) return false;
    std::uint8_t request[] = {1, GET_STATUS, 1, 0};
    for (unsigned length = 0; length < 4; ++length)
        if (validateControl(request, length) != INVALID_PAYLOAD) return false;
    for (unsigned opcode : {GET_STATUS, START_SCAN}) {
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
    request[1] = 3; // Future credential opcodes must not be accepted.
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
