set(adc_sources "")
if(CONFIG_BATTERY_ADC_SOURCE_FAKE)
    list(APPEND adc_sources "fake_adc.cpp")
endif()
idf_component_register(
    SRCS ${adc_sources}
    INCLUDE_DIRS "include"
    REQUIRES acquisition
)
