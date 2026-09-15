idf_component_register(
    SRCS "main.cpp"
    INCLUDE_DIRS "."
    PRIV_REQUIRES adc log wifi board acquisition diagnostics protocol
)