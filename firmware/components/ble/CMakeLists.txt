idf_component_register(
    SRCS "ble_manager.cpp" "wifi_provisioning.cpp" "credential_provisioning.cpp"
    INCLUDE_DIRS "include"
    REQUIRES acquisition diagnostics bt wifi
    PRIV_REQUIRES nvs_flash log esp_wifi esp_timer esp_hw_support
)
