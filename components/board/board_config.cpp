#include "board_config.hpp"
#include "sdkconfig.h"

namespace board {

#if defined(CONFIG_IDF_TARGET_ESP32)
// Classic ESP32 / ESP-32S development board. All GPIO mappings are still TBD.
const BoardConfig config{"ESP32"};
#elif defined(CONFIG_IDF_TARGET_ESP32S3)
// Final ESP32-S3 board. All GPIO mappings are still TBD.
const BoardConfig config{"ESP32-S3"};
#else
#error "Board configuration supports ESP32 and ESP32-S3 only"
#endif

} // namespace board