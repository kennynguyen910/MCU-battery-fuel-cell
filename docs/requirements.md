# System requirements

Planned requirements; this starter only provides a fake ADC and frame interface.

| Area | Requirement |
| --- | --- |
| Measurement channels | 16 |
| Input range | ±5 VDC |
| Measurement resolution | ≥16 bits |
| Sampling rate | ≥1 kSPS per channel |
| Isolation | ≥1 kV |
| Communications | Ethernet, CAN, BLE, Wi-Fi |
| Local display | OLED |
| Firmware | C++ using ESP-IDF and FreeRTOS on ESP32-S3 |

Hardware selection, isolation test conditions, measurement accuracy, and
communications throughput budgets remain to be specified. Communications must
not block ADC acquisition. Real hardware and sustained-rate validation are deferred.
