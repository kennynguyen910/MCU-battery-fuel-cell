#include "board_config.hpp"
#include "sdkconfig.h"

namespace board {

#if defined(CONFIG_IDF_TARGET_ESP32)
// Classic ESP32 display pins confirmed by the user; other mappings remain TBD.
const BoardConfig config = [] {
    BoardConfig value{"ESP32"};
    value.DISPLAY_SDA = 21;
    value.DISPLAY_SCL = 22;
    return value;
}();
#elif defined(CONFIG_IDF_TARGET_ESP32S3)
// Final ESP32-S3 board. All GPIO mappings are still TBD.
const BoardConfig config = [] {
    BoardConfig value{"ESP32-S3"};
#if CONFIG_BATTERY_DISPLAY_PROBE || CONFIG_BATTERY_LCD_CYCLING
    value.DISPLAY_SDA = CONFIG_BATTERY_DISPLAY_S3_SDA;
    value.DISPLAY_SCL = CONFIG_BATTERY_DISPLAY_S3_SCL;
#endif
    return value;
}();
#else
#error "Board configuration supports ESP32 and ESP32-S3 only"
#endif

} // namespace board