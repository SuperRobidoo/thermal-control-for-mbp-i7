# Thermal Control (Intel MBP i7)

Thermal Control is a macOS menu bar and dashboard app for monitoring thermal behavior and managing fan speed on Intel-based MacBook Pro systems.

It samples thermal telemetry using `powermetrics`, visualizes thermal pressure and risk, stores short-term history, and can optionally switch fan control between automatic and manual modes.

## Features

- Live CPU and GPU temperature monitoring
- Thermal pressure state: Nominal, Moderate, Heavy, Trapping
- Throttle risk card based on temperature, thermal level, and prochot events
- Fan speed display with optional manual RPM control
- Power limit indicators and prochot counter
- Local notification alerts with configurable threshold and cooldown
- Menu bar popover for quick status view
- Rolling history (up to 3 hours)

## Requirements

- macOS 13+
- Xcode 15+ recommended
- Intel MacBook Pro target hardware (project focus is MBP i7)
- Administrator access on first run (one-time privilege setup)

## Build And Run

1. Clone the repository:

```bash
git clone https://github.com/SuperRobidoo/thermal-control-for-mbp-i7.git
cd thermal-control-for-mbp-i7
```

2. Open the project in Xcode:

```bash
open 'Thermal Control.xcodeproj'
```

3. Select the `Thermal Control` scheme and run.

## First-Run Privilege Setup

On first launch, the app may show a **Permission Required** banner. Clicking **Grant Access** triggers macOS admin authentication and performs one-time setup:

- Installs the bundled helper to `/usr/local/bin/tc-fan-helper`
- Writes `/etc/sudoers.d/thermalcontrol` with a restricted NOPASSWD rule for:
  - `/usr/bin/powermetrics`
  - `/usr/local/bin/tc-fan-helper`

This enables non-interactive sampling and fan commands while the app is running.

## Security Notes

- The app is not sandboxed.
- `powermetrics` is executed through `sudo -n`.
- Fan write operations also use `sudo -n` via the installed helper.
- The sudoers entry is intentionally narrow, but it still grants elevated command execution for the listed binaries.

Review this behavior before using in managed or production environments.

## Notifications

The app supports local alerts when thermal pressure reaches a configured threshold.

- Enable or disable alerts
- Choose threshold (Moderate, Heavy, Trapping)
- Configure cooldown (10-300 seconds)
- Set a custom message

Notification authorization is requested from macOS and can be changed in System Settings.

## Data Storage

History is stored locally in Application Support:

- `~/Library/Application Support/Thermal Control/history.json`

No network calls are required by default.

## Uninstall And Privilege Cleanup

To remove installed privilege artifacts:

```bash
sudo rm -f /etc/sudoers.d/thermalcontrol
sudo rm -f /usr/local/bin/tc-fan-helper
```

Then delete the app and optional history file:

```bash
rm -f "$HOME/Library/Application Support/Thermal Control/history.json"
```

## Troubleshooting

### App shows permission required repeatedly

- Verify `/etc/sudoers.d/thermalcontrol` exists and has mode `440`
- Verify `/usr/local/bin/tc-fan-helper` exists and is executable
- Validate sudoers syntax:

```bash
sudo visudo -cf /etc/sudoers.d/thermalcontrol
```

### No thermal updates

- Confirm `powermetrics` is available:

```bash
which powermetrics
```

- Check app logs in Xcode console for stderr emitted by `powermetrics`

### Fan control unavailable

- Ensure privilege setup completed successfully
- Confirm helper binary exists at `/usr/local/bin/tc-fan-helper`

## Development

- Language: Swift 5
- UI: SwiftUI
- Tests: `Thermal ControlTests`, `Thermal ControlUITests`

To run tests in Xcode: Product -> Test.

## License

No license file is currently included. If you want others to use, modify, or distribute this project, add an explicit license.