# ThrottleBar

A tiny macOS menu bar app that shows **whether your Apple Silicon Mac is throttling**, styled like the two-line indicators of [Stats](https://github.com/exelban/stats). Sister app of [AIUsageBar](https://github.com/hsxcix/AIUsageBar).

![ThrottleBar (left) next to other Stats-style tiles, under full CPU load](docs/preview.png)

*ThrottleBar on the left, under full CPU load on a MacBook Air M5.*

- **Top line: thermal pressure** as reported by macOS itself: normal, moderate, heavy, critical.
- **Bottom line: P-core clock in % of its maximum** while the CPU is busy. 100% = full speed, 75% = the chip is holding back. Shows `–` when the CPU is idle, because an idle Mac clocks down anyway and there is nothing meaningful to measure.
- **Click for details:** P- and E-core clock in GHz and load, peak clock, how long the Mac has been throttling, launch at login.
- **No root, no helper, no colours.** One Swift file, no dependencies. Menu in English or German, following your system language.

Fanless MacBook Airs throttle after a few minutes of sustained load. Thin MacBook Pros can too; the same signals work there.

## Requirements

- macOS 14 or later, Apple Silicon (built and tested on macOS 27, M5)
- For building: Xcode Command Line Tools (`xcode-select --install`)

## Install

### Download

Grab `ThrottleBar.zip` from [Releases](../../releases), unzip it and move `ThrottleBar.app` to `/Applications`.

The app is not notarized by Apple, so on first launch macOS will block it as unverified. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to ThrottleBar. Or build it yourself (below), which avoids the warning.

### Build from source

```bash
git clone https://github.com/hsxcix/ThrottleBar.git
cd ThrottleBar
./build.sh
```

This compiles `main.swift`, creates `ThrottleBar.app` in the same folder, signs it ad hoc and starts it. New menu bar items appear on the left; hold ⌘ and drag to move it.

To check the raw readings in the terminal:

```bash
ThrottleBar.app/Contents/MacOS/ThrottleBar --sample
```

## How it works

1. **Thermal pressure** comes from the system notification key `com.apple.system.thermalpressurelevel` (falls back to `ProcessInfo.thermalState`). This is what macOS uses to decide how hard to hold the chip back.
2. **Clock speed** comes from Apple's `IOReport` framework (group *CPU Stats → CPU Core Performance States*): for every core, how long it spent idle and in each performance state during the last two seconds.
3. The performance states are mapped to real frequencies using the chip's own tables (`voltage-states1-sram` / `voltage-states5-sram` on the `pmgr` device in the IORegistry), so no per-chip lists are hard-coded.
4. The shown % is the average clock of the busy P-cores divided by the highest P-core clock, smoothed a little, and only shown when the P-cores are at least 25% busy.

Nothing leaves your Mac: no network access, no analytics, nothing written to disk except the app's own preferences.

**Caveats:** `IOReport` and the frequency tables are private Apple interfaces. They have been stable for years and are used by tools like Stats, but a macOS update could break them; the thermal pressure line would keep working. Intel Macs are not supported. Not affiliated with or endorsed by Apple.

## License

**All rights reserved**, provided as is without any warranty. See [LICENSE](LICENSE).

In practice I don't really mind if you use it. I just keep all rights and decide case by case. If you want explicit permission (for example to fork, redistribute or build on it), open an issue or contact me on GitHub.
