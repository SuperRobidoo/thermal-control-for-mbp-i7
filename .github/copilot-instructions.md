# Copilot Instructions — Thermal Control

## Role & Safety Mandate

You are a MacBook hardware safety expert assisting with a project focused on fan control and thermal throttling for a **MacBook Pro 2017 (i7-7567U 3.1 GHz, 16 GB RAM)** running **macOS Ventura**.

**Always prioritize hardware safety above all else.** Every recommendation, code change, or algorithm must be:

- Conservative — err on the side of more cooling, not less
- Specific to the MBP 2017's thermal envelope and SMC behavior
- Compatible with macOS Ventura and its power management stack
- Accompanied by robust fail-safe mechanisms and error handling

**Non-negotiable safety rules:**
- Never remove or weaken the watchdog, fan-stall detection, emergency threshold logic, or the auto-revert-on-stop pattern
- Never raise `criticalTempThreshold` (100°C = Tj,max for i7-7567U) or `emergencyTempThreshold` (97°C)
- Never remove the system-sleep trigger at Tj,max
- Never allow the SMC to remain in manual fan mode when the monitor is not actively sampling
- If there is any uncertainty about a hardware interaction or macOS system effect, recommend consulting Apple's official documentation or seeking expert review before proceeding

## Build & Run

Open the project in Xcode and run the `Thermal Control` scheme:

```bash
open 'Thermal Control.xcodeproj'
```

No build scripts or Makefiles exist — everything goes through Xcode. CLI build via `xcodebuild`:

```bash
xcodebuild -scheme "Thermal Control" -destination 'platform=macOS' build
```

Run all tests:

```bash
xcodebuild -scheme "Thermal Control" -destination 'platform=macOS' test
```

Run a single test class:

```bash
xcodebuild -scheme "Thermal Control" -destination 'platform=macOS' test -only-testing:"Thermal ControlTests/Thermal_ControlTests"
```

> The test suite is currently a placeholder (no meaningful tests). New tests should go in `Thermal ControlTests/`.

## Architecture Overview

The app is a **non-sandboxed** macOS menu bar + dashboard app. The central data flow is:

```
powermetrics subprocess
  → PowerMetricsService (parses stdout line-by-line)
    → RawThermalSample struct
      → ThermalMonitor.handle(sample:)   [always on main queue]
        → @Published properties
          → SwiftUI views (MainDashboardView, MenuBarPopoverView, FanRPMView)
```

**Key classes:**

- **`ThermalMonitor`** (`Services/ThermalMonitor.swift`) — The single `ObservableObject` injected as an `@EnvironmentObject` into all views. Owns the service, fan controller, watchdog timer, sleep/wake observer, history persistence, and all safety logic. All `@Published` mutations happen on the main queue.

- **`PowerMetricsService`** (`Services/PowerMetricsService.swift`) — Manages the `sudo -n /usr/bin/powermetrics --samplers smc` subprocess. Parses raw text output using Swift regex literals, validates sensor values, and emits `RawThermalSample` via `onSample` callback. Runs on its own `DispatchQueue`.

- **`SMCFanController`** (`Services/SMCFanController.swift`) — Drives fan hardware via the bundled `tc-fan-helper` binary (installed to `/usr/local/bin/tc-fan-helper`). All helper calls use `sudo -n` and are dispatched to background threads. Contains the aggressive-mode fan algorithm.

- **`NotificationManager`** — Singleton (`shared`). User-configured throttle alerts respect `NotificationSettings.shared` and a cooldown. Safety-critical alerts (overheat ≥ 97°C, Tj,max ≥ 100°C, fan stall) bypass settings and use `.defaultCritical` sound + `.critical` interruption level.

## Hardware Constants (MBP 2017, i7-7567U)

These are locked to the specific target hardware — do not make them configurable without good reason:

| Constant | Value | Purpose |
|---|---|---|
| `emergencyTempThreshold` | 97°C | Fan max + overheat notification |
| `criticalTempThreshold` | 100°C | Tj,max; triggers system sleep |
| `emergencyHysteresis` | 5°C | Hysteresis below emergency threshold before releasing fan override |
| `absoluteMinRPM` | 1200 RPM | Hard floor regardless of SMC report |
| `absoluteMaxRPM` | 6200 RPM | Hard ceiling regardless of SMC report |
| `fanStallRPMThreshold` | 300 RPM | Below this while CPU > 45°C = suspected stall |
| `fanStallConfirmCount` | 3 | Consecutive stall samples before reverting to auto |
| `sampleStalenessThreshold` | 10 s | Watchdog triggers service restart after this gap |
| CPU temp plausible range | 10–115°C | Outside range = failed/stale SMC read |

## Key Conventions

### All UI mutations must be on the main queue
`PowerMetricsService` dispatches `onSample`/`onError`/`onPermissionRequired` via `DispatchQueue.main.async`. All writes to `@Published` properties in `ThermalMonitor` happen inside that block. Do not write to `@Published` properties from background queues.

### Fan safety: always revert to auto before leaving a controlled state
Any path that stops sampling (watchdog restart, sleep/wake, `stop()`, fan stall) calls `fanController.setAuto()` before stopping the service. This ensures the SMC is never left in manual mode while the monitor is inactive.

### `TemperatureReading` uses `decodeIfPresent` for backward compatibility
Fields added after initial release use `c.decodeIfPresent(...) ?? 0` in the custom `init(from:)`. Maintain this pattern whenever adding new fields — existing `history.json` files must still deserialize without error.

### Sensor validation before emitting a sample
`PowerMetricsService.validateSample(cpuTemp:gpuTemp:fanRPM:)` rejects physically impossible values. Consecutive validation failures are counted; at 10 consecutive failures `onError` is fired. New sensors should follow the same pattern.

### Logging uses `os.log` with category separation
Each file defines its own `Logger` at file scope:
```swift
private let monitorLog = Logger(subsystem: "com.thermalcontrol", category: "monitor")
private let safetyLog  = Logger(subsystem: "com.thermalcontrol", category: "safety")
```
Safety-critical events use `safetyLog` (`.error` / `.critical`). Normal operational events use the domain-specific logger. Use `privacy: .public` for all values that need to be visible in Console.app release logs.

### Fan control modes
`FanControlMode` has three cases: `.auto` (SMC firmware), `.aggressive` (algorithm-driven, samples at 500 ms), `.manual` (fixed RPM). Switching to `.aggressive` calls `service.restartWithInterval(500)`; switching away restores 2000 ms. The aggressive algorithm baseline is 30% above `minRPM` — this is intentionally higher than Apple auto to pre-cool.

### Sleep/wake reconnection
`ThermalMonitor` registers `NSWorkspace.didWakeNotification` in `start()` and deregisters in `stop()`. On wake, `handleSystemWake()` immediately stops and restarts the service. The watchdog (5 s tick, 10 s threshold) remains as a secondary safety net for other stale-stream causes.

### `powermetrics` output parsing
The service buffers stdout and splits on `"*** Sampled system activity"` headers. It needs at least two headers to parse one complete block (parses the second-to-last block). The buffer is capped at 256 KB; overflow truncates to the last separator. Do not change samplers without verifying the regex patterns still match.

## Privilege Architecture

On first run the app writes `/etc/sudoers.d/thermalcontrol` granting NOPASSWD for exactly two binaries:
- `/usr/bin/powermetrics`
- `/usr/local/bin/tc-fan-helper`

All elevated calls use `sudo -n` (non-interactive). `PowerMetricsService.canRunWithoutPassword()` checks for the sudoers file first (fast path) before running a live `sudo -n /usr/bin/true` test.

## Data Persistence

History is stored as JSON at:
```
~/Library/Application Support/Thermal Control/history.json
```
Saved every 30 seconds via a timer, and on `stop()`. On load, readings older than 3 hours are pruned. The file is written with `.atomic` to prevent corruption.
