# auto Mac Network Location

Automatically detects your current Wi-Fi SSID and switches to a predefined network location

## Installation

```bash
sudo ./locationchanger.sh install
```

Features
--------

*   Auto-detects Wi-Fi network changes
*   Configurable SSID-to-Location Mapping
*   Real-time location switching
*   Logging With Rotation
*   Install/uninstall
*   Permission management

Configuration
-------------

Modify your network locations by editing the line starting at `156` in the script


Environment Variables
---------------------

Adjust the script’s environment variables starting at line `18` to suit your system configuration or preferences

Uninstall
---------

If you need to uninstall the script and remove its configurations, execute:

```bash
sudo ./locationchanger.sh uninstall

```
