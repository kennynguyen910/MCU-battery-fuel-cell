#pragma once

namespace packetizer_test {

// DEVELOPMENT ONLY: fixed vectors, no hardware or logging. Call once at startup
// or from a host test runner; never call this on the acquisition path.
bool runSelfTest();

} // namespace packetizer_test