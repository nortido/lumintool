# LuminTool

LuminTool is a small macOS menu bar app that sets the brightness of an external monitor from a Home Assistant illuminance sensor. You calibrate the brightness you want, and LuminTool adjusts the monitor as the light changes.

## Requirements

- A Mac with an Apple M-series chip (Intel Macs are not supported)
- macOS 14 or later
- An external monitor that the macOS brightness slider can control
- A Home Assistant sensor that reports lx

LuminTool keeps the Home Assistant token in the macOS Keychain. Brightness goes through the private DisplayServices framework, so a macOS update may break it.

## License

GPL-3.0, see [LICENSE](LICENSE).
