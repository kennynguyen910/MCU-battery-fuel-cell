idf_component_register(
    SRCS "packetizer.cpp" "packetizer_self_test.cpp"
    INCLUDE_DIRS "include"
    REQUIRES acquisition
)