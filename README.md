<p align="center"><img src="docs/icon.png" width="140" alt="BusyCat app icon"></p>

<h1 align="center">BusyCat (바쁘냥)</h1>

A macOS menu-bar app like [RunCat](https://github.com/Kyome22/menubar_runcat) — a
running cat whose speed reflects how busy your Mac is. Unlike RunCat, **BusyCat
watches the GPU as well as the CPU**, so heavy GPU work (ML training, embeddings,
rendering) makes the cat run too.

🇰🇷 [한국어 README](README.ko.md)

<p align="center"><img src="docs/demo.gif" alt="BusyCat running in the menu bar"></p>

## Why

RunCat only watches the CPU, so GPU-bound work — for example running ML
embeddings on Apple Silicon — leaves the cat looking idle. BusyCat drives the cat
from **`max(CPU, GPU)`**: whatever is busiest.

RunCat can't add GPU support because it's a sandboxed App Store app (no GPU or
thermal access — the developer says so in the FAQ). BusyCat ships *outside* the
App Store, so it can read the GPU via IOKit without `sudo`.

## Features

- Running cat in the menu bar, speed ∝ system load.
- Watches **CPU and GPU**. Pick what drives the speed: busiest (CPU·GPU), CPU
  only, GPU only, or memory.
- **Detailed live panel** (click the cat): CPU, GPU, memory, disk, thermal state,
  network, battery — each mapped to Activity Monitor's own definitions where
  macOS exposes a comparable value.
- **Temperature details on hover**: hottest sensor, macOS thermal pressure,
  `pmset` speed limits, and top temperature sensors are shown separately.
- Choose the menu-bar text: hidden, cat-speed %, CPU %, GPU %, memory %,
  temperature, or thermal pressure.
- Optional small **RAM fish pile** next to the cat when memory pressure rises.
- Invert speed (busier = slower), flip the cat's direction, choose cat color
  (auto contrast / white / black). Optionally add a red outline to the cat when
  thermal pressure is above nominal.
- **Lightweight:** when the menu is closed, BusyCat reads only the values needed
  to drive the cat, keeping idle CPU low.
- No Dock icon (`LSUIElement`). Settings persist (`UserDefaults`).

<p align="center"><img src="docs/panel.png" width="300" alt="BusyCat detailed stats panel"></p>

## Menu Layout

Click the cat to open the menu. Items are ordered like this:

1. Current speed-driver summary
2. Detailed CPU/GPU/memory/disk/thermal/battery/network panel
3. Settings
4. Open Activity Monitor
5. Check for updates
6. Quit BusyCat

Use `Settings` to choose language, menu-bar display, speed behavior, design, and
launch at login in one place. Hover the thermal row in the stats panel to see
temperature sensor details. BusyCat ships Korean and English UI text only; the
default language is Korean for `ko` system languages and English otherwise.

## Default Settings

Fresh installs start quiet and conservative:

- Language: system language (Korean for `ko`, English otherwise)
- Speed source: busiest of CPU/GPU
- Menu-bar text: hidden
- Memory pressure fish: off
- Cat color: white
- Graph/bar color: graphite
- Speed invert: off
- Flip direction: off
- Red thermal outline: off
- Launch at login: off

## 🧪 Experimental: multi-cat mode

A multi-cat mode is prototyped and working — a separate **CPU cat** and **GPU cat**
each spinning at its own load. Public release of this mode is on hold pending
artwork licensing: the prototype used a popular meme-cat sprite, so the
distributed build ships only with the licensed running-cat art and the
hand-drawn memory fish gauge for now. If you're the rights holder and object,
open an issue and it'll be removed.

## Build & install

Requires the macOS Swift toolchain (Xcode Command Line Tools). No other
dependencies.

```bash
./make_app.sh            # build BusyCat.app (ad-hoc signed)
./make_app.sh --install  # build + copy to /Applications + relaunch
```

Quit from the cat's menu → **Quit BusyCat** (⌘Q). To launch at login, add
`BusyCat.app` under System Settings → General → Login Items.

## Updating

BusyCat checks GitHub Releases once a day; when a newer version is published it
shows **🆕 Get v...** in its menu (or click **Check for Updates** any time). It only
*notifies* — there's no Sparkle/auto-install (it's an ad-hoc-signed app) — so you
update by pulling and rebuilding:

```bash
git pull
./make_app.sh --install   # quits, replaces /Applications/BusyCat.app, relaunches
```

## How it works

- **GPU** (Apple Silicon, no `sudo`): IOKit `IOAccelerator` →
  `PerformanceStatistics`. Compute load = `Device Utilization %` − `Renderer
  Utilization %`, which isolates real compute (Metal/MPS) from
  graphics/compositing — this is what climbs during ML work, cross-checked
  against Activity Monitor.
- **CPU**: `host_statistics` `HOST_CPU_LOAD_INFO` tick deltas, EMA-smoothed so it
  tracks Activity Monitor's feel.
- **Memory / disk / network / battery / thermal state**: `vm_statistics64`,
  volume capacity, `getifaddrs` byte deltas, IOKit `AppleSmartBattery`,
  `ProcessInfo.thermalState`, IOHID/AppleSMC temperature sensors, and
  `pmset -g therm` where available.
- **Temperature vs thermal pressure**: the temperature shown in the menu is the
  hottest valid SMC/IOHID sensor. Thermal pressure is macOS' own
  `nominal / fair / serious / critical` state, which also reflects power,
  scheduling, and throttling headroom. A Mac can report 60-100°C while still
  being nominal, or throttle before a single sensor looks alarming.
- **Sampling optimization**: when the menu is closed, BusyCat reads only the
  CPU/GPU/memory values needed to drive the cat. Disk, network identity, battery,
  full temperature sensors, and `pmset` are sampled only while the menu is open;
  slow-changing values are cached for about 5 seconds, and `pmset -g therm` is
  cached for about 30 seconds.
- **Accuracy caveats**: GPU load is a best-effort interpretation of Apple
  Silicon IOKit counters, and temperature sensor names are model-specific rather
  than stable public API. BusyCat therefore shows temperature as the hottest
  valid sensor it can read, while macOS thermal pressure remains the primary
  signal for real throttling pressure.
- **Rendering**: a `CALayer` sprite swapped by a timer (avoids the heavy menu-bar
  recomposite path on recent macOS).
- **Speed**: `interval = 0.4 / clamp(usage / 5, 1...20)` → ~2.5 fps idle,
  ~50 fps at full load.

Source lives in `Sources/BusyCat/`: `UsageReader.swift` (sampler),
`AppDelegate.swift` (status item + animation), `StatsView.swift` (panel),
`CatFrames.swift` (sprites).

## Credits & license

- Code: **MIT** — see [LICENSE](LICENSE).
- Cat sprites: from [RunCat](https://github.com/Kyome22/menubar_runcat) by Takuto
  Nakamura, **Apache License 2.0** — see
  [THIRD_PARTY_LICENSE-RunCat.txt](THIRD_PARTY_LICENSE-RunCat.txt). The
  speed-mapping formula is also adapted from RunCat. `assets/cat0–4.png` are the
  original frames; the app icon is derived from them.
