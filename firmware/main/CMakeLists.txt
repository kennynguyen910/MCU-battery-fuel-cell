idf_component_register(
    SRCS "main.cpp" "network_consumer.cpp"
    INCLUDE_DIRS "."
    PRIV_REQUIRES adc log wifi board acquisition diagnostics protocol udp esp_timer ble
)
