# AutoClicker

A small macOS auto clicker with a 1-bit, classic-Mac-style interface.

## Features

- Click interval with optional random jitter (±ms)
- Start delay
- Pause: rest for a set time after every N clicks, then keep going
- Left, right or middle button; single or double click
- Click at the cursor or at a fixed screen position (Pick it with a 3-second countdown)
- Stop manually, after N clicks, or after N seconds
- **F6** global hotkey to start/stop from any app
- Settings are remembered between launches

## Build

Requires the Xcode command line tools (`xcode-select --install`) and macOS 14 or later.

```sh
./build.sh
open AutoClicker.app
```

The app needs **Accessibility** permission to send clicks
(System Settings → Privacy & Security → Accessibility). The build is ad-hoc signed,
so after each rebuild you may need to remove and re-add it there.

## Font

The UI uses [ChicagoFLF](https://fontlibrary.org/font/chicagoflf) by Robin Casady,
which is in the public domain. See `Fonts/README.ChicagoFLF`.
