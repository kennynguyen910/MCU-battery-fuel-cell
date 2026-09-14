idf_component_register(
    SRCS "fake_adc.cpp"
    INCLUDE_DIRS "include"
    REQUIRES acquisition
    PRIV_REQUIRES esp_timer
)
