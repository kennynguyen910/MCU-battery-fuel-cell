idf_component_register(
    SRCS "acquisition.cpp"
    INCLUDE_DIRS "include"
    REQUIRES freertos esp_driver_gptimer diagnostics
    PRIV_REQUIRES esp_timer log
)