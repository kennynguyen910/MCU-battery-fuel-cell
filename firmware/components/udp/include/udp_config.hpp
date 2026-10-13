#pragma once

#include <cstdint>

namespace udp_config {

// Destination is provisioned into wifi_cfg; no default laptop receiver.

// Flush an incomplete batch after 20 ms from its first buffered frame.
inline constexpr std::int64_t BATCH_FLUSH_TIMEOUT_US = 20000;
} // namespace udp_config
