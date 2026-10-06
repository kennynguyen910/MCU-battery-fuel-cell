# ESP32 firmware

This directory is the ESP-IDF project root. Run idf.py build here. Flash commands also belong here and target only this firmware project. Never add ../mobile_app/ as a component.

The local main/ and components/ directories supply application sources. examples/ contains preserved, uncompiled desktop and optional USB console examples.

Shared protocols and test instructions are in [../docs/](../docs/), and repository setup is in [../README.md](../README.md). Firmware-only tools run here; shared compatibility checks run from the repository root.
