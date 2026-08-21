# ESP-IDF ignores PlatformIO src_filter. Pick sources from D400_NCM_TARGET
# (passed via board_build.cmake_extra_args). Arduino is an extra component
# named after its package folder.

set(D400_NCM_TARGET "ride" CACHE STRING "NCM firmware target: bench or ride")

set(D400_REQUIRES
  nvs_flash
  esp_netif
  esp_event
  esp_timer
  driver
  framework-arduinoespressif32
)

if(D400_NCM_TARGET STREQUAL "bench")
  idf_component_register(
    SRCS "usb_ncm.c" "main_ncm_bench.cpp"
    INCLUDE_DIRS "."
    REQUIRES ${D400_REQUIRES}
  )
else()
  idf_component_register(
    SRCS
      "usb_ncm.c"
      "main_ride.cpp"
      "sse_transport.cpp"
      "telemetry_format.cpp"
      "can_ingest.cpp"
      "passive_decode.cpp"
      "trip_computer.cpp"
      "twai_can.cpp"
      "bench_metrics.cpp"
    INCLUDE_DIRS "."
    REQUIRES ${D400_REQUIRES}
  )
endif()

