idf_component_register(
    SRCS "main.cpp" "network_consumer.cpp"
    INCLUDE_DIRS "."
    PRIV_REQUIRES adc log wifi board acquisition diagnostics protocol udp esp_timer ble
)

if(CONFIG_BATTERY_DISPLAY_PROBE)
    target_sources(${COMPONENT_LIB} PRIVATE "i2c_display_probe.cpp")
endif()

if(CONFIG_BATTERY_LCD_STARTUP_TEST OR CONFIG_BATTERY_LCD_CYCLING)
    target_sources(${COMPONENT_LIB} PRIVATE "lcd1602_startup.cpp")
endif()

if(CONFIG_BATTERY_DISPLAY_PROBE OR CONFIG_BATTERY_LCD_CYCLING)
    idf_component_optional_requires(PRIVATE esp_driver_i2c esp_driver_gpio esp_rom)
endif()
if(CONFIG_BATTERY_LCD_CYCLING)
    target_sources(${COMPONENT_LIB} PRIVATE "lcd_display.cpp" "lcd_display_format.cpp")
endif()
