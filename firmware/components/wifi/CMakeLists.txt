idf_component_register(
    SRCS "wifi_manager.cpp" "wifi_credentials.cpp" "wifi_scan.cpp"
    INCLUDE_DIRS "include"
    REQUIRES esp_event esp_netif
    PRIV_REQUIRES esp_wifi nvs_flash log
)