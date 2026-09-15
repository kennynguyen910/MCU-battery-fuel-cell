#pragma once

#include <cstdint>

namespace acquisition_config {

inline constexpr std::uint32_t PERIOD_US = 1000;
inline constexpr std::uint32_t QUEUE_CAPACITY = 128;
// Application priorities; leave the higher ESP-IDF system priorities available.
inline constexpr std::uint32_t ACQUISITION_PRIORITY = 5;
inline constexpr std::uint32_t CONSUMER_PRIORITY = 3;
// A wake more than 250 us after its scheduled alarm is classified as late.
inline constexpr std::uint32_t LATE_THRESHOLD_US = 250;

// DEVELOPMENT / TEST ONLY. Normal operation does not delay the consumer.
// Set true and rebuild for test E; use 250 ms for deliberate overflow (test F).
inline constexpr bool ENABLE_CONSUMER_STRESS_TEST = false;
inline constexpr std::uint32_t STRESS_PAUSE_MS = 50;
inline constexpr std::uint32_t STRESS_EVERY_FRAMES = 1000;

} // namespace acquisition_config