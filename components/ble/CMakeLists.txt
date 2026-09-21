idf_component_register(
    SRCS "ble_manager.cpp"
    INCLUDE_DIRS "include"
    REQUIRES acquisition diagnostics bt
    PRIV_REQUIRES nvs_flash log
)
