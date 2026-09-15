idf_component_register(
    SRCS "diagnostics.cpp"
    INCLUDE_DIRS "include"
    REQUIRES freertos
    PRIV_REQUIRES esp_timer log
)