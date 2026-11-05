# LuminTool

LuminTool is a small macOS menu bar app that sets the brightness of an external monitor from an illuminance sensor. You calibrate the brightness you want, and LuminTool adjusts the monitor as the light changes.

## Requirements

- A Mac with an Apple M-series chip (Intel Macs are not supported)
- macOS 14 or later
- An external monitor that the macOS brightness slider can control
- An illuminance sensor that reports lx, read through one of four sources: Home Assistant, MQTT, USB or ESPHome

## Sources

- Home Assistant: a sensor entity that reports lx, and a long-lived access token.
- MQTT: a broker URL (`mqtt://` or `mqtts://`) and a topic. Leave the JSON key empty to find the lux value automatically in Zigbee2MQTT and Tasmota messages. For other devices, such as the SLS gateway, enter the key that holds the lux value.
- USB: a board that prints one lux number per line, at least every 10 seconds, at 115200 baud by default. See [examples/bh1750-serial](examples/bh1750-serial/bh1750-serial.ino) for a BH1750 sketch.
- ESPHome: enable `web_server:` on the device and use its address, for example `http://name.local`. A login is optional.

LuminTool keeps the Home Assistant token and the passwords in the macOS Keychain. Brightness goes through the private DisplayServices framework, so a macOS update may break it.

## License

GPL-3.0, see [LICENSE](LICENSE).
