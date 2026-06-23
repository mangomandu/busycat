# BusyCat (바쁘냥)

A macOS menu-bar app like [RunCat](https://github.com/Kyome22/menubar_runcat) — a
running cat whose speed reflects how busy your Mac is. Unlike RunCat, **BusyCat
watches the GPU as well as the CPU**, so heavy GPU work (ML training, embeddings,
rendering) makes the cat run too.

🇰🇷 [한국어 README](README.ko.md)

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
- **Detailed live panel** (click the cat): CPU, GPU, memory, disk, network,
  battery — each mapped to Activity Monitor's own definitions.
- Show the load **%** next to the cat (toggle).
- Invert speed (busier = slower), flip the cat's direction, choose cat color
  (auto / white / black).
- **Lightweight:** ~0.1% idle CPU — lighter than RunCat while watching more.
- No Dock icon (`LSUIElement`). Settings persist (`UserDefaults`).

## Build & install

Requires the macOS Swift toolchain (Xcode Command Line Tools). No other
dependencies.

```bash
./make_app.sh            # build BusyCat.app (ad-hoc signed)
./make_app.sh --install  # build + copy to /Applications + relaunch
```

Quit from the cat's menu → **바쁘냥 종료** (⌘Q). To launch at login, add
`BusyCat.app` under System Settings → General → Login Items.

## How it works

- **GPU** (Apple Silicon, no `sudo`): IOKit `IOAccelerator` →
  `PerformanceStatistics`. Compute load = `Device Utilization %` − `Renderer
  Utilization %`, which isolates real compute (Metal/MPS) from
  graphics/compositing — this is what climbs during ML work, cross-checked
  against Activity Monitor.
- **CPU**: `host_statistics` `HOST_CPU_LOAD_INFO` tick deltas, EMA-smoothed so it
  tracks Activity Monitor's feel.
- **Memory / disk / network / battery**: `vm_statistics64`, volume capacity,
  `getifaddrs` byte deltas, and IOKit `AppleSmartBattery` — each matched to
  Activity Monitor's definitions.
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
