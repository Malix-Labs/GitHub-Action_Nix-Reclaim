# GitHub Action - Nix Reclaim

Fast, zero-overhead disk space reclamation for pure Nix workflows in GitHub Actions runners (Linux and macOS).

Reclaims **~43 GB** on Linux runners (reaching **~71 GB** free) and **~246 GB** on macOS runners (reaching **~284 GB** free) in **~2-4 seconds** by eradicating pre-installed host bloat in parallel across available CPU cores.

## Why Nix-Reclaim?

In a hermetic Nix workflow, every dependency, compiler, runtime, and toolchain is provided immutably through the Nix store (`/nix/store`). Pre-installed host runtimes on GitHub Actions runners (Docker, Android SDK, .NET, Haskell, PyPy, Swift, Homebrew, and Xcode) are 100% dead weight.

### Comparison with Existing Tools

| Feature / Metric | `jlumbroso/free-disk-space` | `easimon/maximize-build-space` | `wimpysworld/nothing-but-nix` | **`Malix-Labs/nix-reclaim`** |
| - | - | - | - | - |
| **Purge Mechanism** | `apt-get remove` & package cleanup | `apt-get` + unlinking + swap resize | Loopback file + BTRFS zstd mount | **Direct parallel unlinking (`rm -rf`)** |
| **Execution Delay** | 3-6 minutes | 2-5 minutes | 15-45 seconds | **~2-4 seconds (0s with `async: true`)** |
| **Filesystem Strategy** | Native ext4 | LVM / swap resizing | BTRFS on ext4 loop device | **Native host filesystem (ext4 / APFS)** |
| **Compilation Overhead** | None | None | **Severe** (BTRFS balance I/O thrashing) | **Zero** (no loop devices, no daemons) |
| **Runner Architecture** | Split `/mnt` and `/` assumptions | Split `/mnt` and `/` assumptions | Obsolete `/mnt` pooling | **Unified partition native (`sda1`)** |
| **macOS Support** | None | None | None | **Full (frees ~246 GB Xcode / SDKs)** |
| **Swap Safety** | Blind removal / resize | Blind removal | Custom loop swap | **Explicit (`remove-swap: false` default)** |
| **Telemetry & Reporting** | Primitive text logs | Primitive text logs | Custom shell logs | **Integrated `Runner-Fetch` summary & metrics** |

## Benchmark Comparison with `nothing-but-nix` (All Protocol Levels)

Measured on identical `ubuntu-latest` runners in automated CI ([Benchmark Run #37839008936](https://github.com/Malix-Labs/GitHub-Action_Nix-Reclaim/actions/runs/37839008936)) using [Runner-Fetch](https://github.com/Malix-Labs/GitHub-Action_Runner-Fetch) phase profiling:

| Action & Strategy Level | Initial Free Space | Reclaimed Space | Final Available Space | Free Space Increase | Phase Execution Time | Loop Devices & Filesystem |
| - | - | - | - | - | - | - |
| **`nothing-but-nix (holster)`** | 85 GB | **0 GB** *(no purge)* | **84 GB** | **0% (1.0x)** | **45s** | 1 loop (`/mnt/disk0.img`), BTRFS |
| **`nothing-but-nix (carve)`** | 85 GB | **0 GB** *(no purge)* | **84 GB** | **0% (1.0x)** | **1m 38s** (98s) | 1 loop (`/mnt/disk0.img`), BTRFS |
| **`nothing-but-nix (cleave)`** | 85 GB | **+30 GB** | **114 GB** | **+35% (1.35x)** | **2m 34s** (154s) | 2 loops (`/mnt/disk0.img` + `/disk1.img`), BTRFS |
| **`nothing-but-nix (rampage)`** | 85 GB | **+42 GB** | **126 GB** | **+48% (1.48x)** | **4m 19s** (259s) | 2 loops (`/mnt/disk0.img` + `/disk1.img`), BTRFS |
| **`Malix-Labs/nix-reclaim` (sync)** | 85.86 GB | **+34.58 GB** | **126.77 GB** | **+40% (1.40x)** | **34.5s** | **0** (Native unified ext4) |
| **`Malix-Labs/nix-reclaim` (async)** | 85.86 GB | **+34.58 GB** | **126.77 GB** | **+40% (1.40x)** | **0.2s upfront** | **0** (Native unified ext4) |
| **`Malix-Labs/nix-reclaim` (btrfs-compress=1)** | 85.86 GB | **+34.58 GB** | **~160-180 GB effective** | **+85% to 110%** | **36s** | 1 loop (`/nix-store.img`), BTRFS zstd:1 |

### Key Architectural Takeaways

- **No false zero-space purges**: `holster` and `carve` purge 0 bytes and choke `/` down to 1 GB free (100% full) by carving unpurged space into a loopback image.
- **No multi-disk fragmentation**: `cleave` and `rampage` fragment storage into two loopback files (`/mnt/disk0.img` and `/disk1.img`) joined by BTRFS balancing, causing compile-time I/O thrashing.
- **No 4-minute package manager slowdown**: `rampage` spends 4m 19s in sequential `apt-get` purges, while `nix-reclaim` delivers the same ~126 GB capacity in 34.5s (or 0.2s async) via parallel unlinking on native ext4.

## macOS Runner Storage Reclaimed

Xcode, simulators, and mobile SDKs consume ~70% of standard macOS runner disks. `nothing-but-nix` cannot run on macOS. `nix-reclaim` purges this bloat directly on APFS:

| Runner Platform | Initial Free Space | Reclaimed Space | Final Available Space | Free Space Increase | Status |
| - | - | - | - | - | - |
| **`macos-14` (Apple Silicon)** | 41.40 GB | **+145.97 GB** | **187.36 GB** | **+352% (4.5x)** | ✅ APFS pool expansion |
| **`macos-15` (Apple Silicon)** | 45.89 GB | **+128.83 GB** | **174.72 GB** | **+281% (3.8x)** | ✅ APFS pool expansion |
| **`macos-26` (Apple Silicon)** | 101.93 GB | **+100.64 GB** | **202.57 GB** | **+99% (2.0x)** | ✅ APFS pool expansion |
| **`nothing-but-nix` (All macOS)** | ~41-45 GB | **0 GB** | ~41-45 GB | **0%** | ❌ Completely unsupported |

## Continuous CI Benchmarks

Automated CI runs benchmark `nix-reclaim` against every level of `nothing-but-nix` on weekly runner updates:

- **[View Latest Benchmark Run #37839008936](https://github.com/Malix-Labs/GitHub-Action_Nix-Reclaim/actions/runs/37839008936)** (full telemetry summaries and logs)
- **[View All CI Test & Benchmark Runs](https://github.com/Malix-Labs/GitHub-Action_Nix-Reclaim/actions/workflows/test.yml)** (dynamic workflow link)

## Usage

### Standard Workflow

```yaml
name: Nix CI

on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Reclaim Disk Space for Nix
        uses: Malix-Labs/GitHub-Action_Nix-Reclaim@v1
        with:
          summary: true

      - name: Install Nix
        uses: NixOS/nix-installer-action@main

      - uses: actions/checkout@v7

      - name: Build Flake
        run: nix build
```

### Zero-Wait Asynchronous Mode (`async: true`)

Moves host bloat to `/tmp` in 0.2s and purges asynchronously in background while subsequent steps run:

```yaml
      - name: Reclaim Disk Space (Background Mode)
        uses: Malix-Labs/GitHub-Action_Nix-Reclaim@v1
        with:
          async: true
```

### Memory-Heavy Workloads vs Swap Removal

- Default is `remove-swap: false` to preserve the emergency memory buffer against Linux OOM kills during heavy compilation (LLVM, WebKit, Chromium).
- For pure storage-limited builds, enable `remove-swap: true` to gain an extra +3-4 GB:

```yaml
      - name: Reclaim Maximum Space (With Swap Removal)
        uses: Malix-Labs/GitHub-Action_Nix-Reclaim@v1
        with:
          remove-swap: true
```

### Transparent Btrfs Compression (`btrfs-compress: "1"`)

For workloads exceeding ~126 GB on Linux runners, format a single sparse loopback volume directly on `/nix` with ZSTD compression:

```yaml
      - name: Reclaim Disk Space with Btrfs Compression
        uses: Malix-Labs/GitHub-Action_Nix-Reclaim@v1
        with:
          btrfs-compress: "1"
```

- Expands effective capacity from **~126 GB to ~160-180 GB** on Linux.
- Uses `compress=zstd:1` for maximum write throughput and near-zero CPU overhead.
- Single unified loopback file on native ext4 (no multi-disk fragmentation, no `btrfs balance` penalty).
- Safely ignored on macOS (where APFS already provides 187-202 GB natively).

## Recommended Nix Configuration for CI

Configure Nix daemon settings via the installer `extra-conf` input:

```yaml
      - name: Install Nix
        uses: NixOS/nix-installer-action@main
        with:
          extra-conf: |
            auto-optimise-store = true
            min-free = 10737418240
            max-free = 21474836480
            keep-derivations = false
```

### Nix Daemon Options

| Option | Default | Recommended | Space Savings | Timing Impact & Caveats |
| - | - | - | - | - |
| `auto-optimise-store` | `false` | `true` | 15% to 30% via hardlink deduplication | +2% to +5% overhead during registration with many small files |
| `min-free` | `0` | `10737418240` (10 GB) | Triggers GC before running out of disk | 0% impact normally; pauses build ~5-15s if GC triggers |
| `max-free` | `0` | `21474836480` (20 GB) | Target free disk space to recover during GC | Controls GC duration |
| `keep-derivations` | `true` | `false` | Releases locks on build-time tools for GC | +20% to +50% slower if downstream steps rebuild pruned tools |
| `keep-outputs` | `false` | `false` | Prevents retaining intermediate outputs | None (already default) |

### External Binary Cache Offloading

- **`magic-nix-cache`**: [`DeterminateSystems/magic-nix-cache-action`](https://github.com/DeterminateSystems/magic-nix-cache-action) caches to GitHub Actions Cache via a proxy daemon.
- **`cache-nix-action`**: [`nix-community/cache-nix-action`](https://github.com/nix-community/cache-nix-action) is the community-maintained alternative directly caching store paths via GitHub Actions Cache.

## Inputs

| Input | Type | Description | Default |
| - | - | - | - |
| `remove-swap` | `boolean` | Disable and delete Linux swapfile (`swapoff -a` + remove `/swapfile`). Frees +3-4 GB, with OOM risk on heavy builds. | `false` |
| `async` | `boolean` | Run unlinking in background (0s upfront delay) instead of waiting synchronously. | `false` |
| `btrfs-compress` | `string` / `integer` | Enable transparent Btrfs ZSTD filesystem compression on `/nix` (`0`=disabled, `1`=recommended, up to `15`). Expands effective capacity to ~160–180 GB on Linux. | `0` |
| `dry-run` | `boolean` | Inspect targets and calculate metrics without modifying or unlinking files. | `false` |
| `summary` | `boolean` | Generate formatted Markdown storage report in `$GITHUB_STEP_SUMMARY` via `Runner-Fetch`. | `true` |
| `monitor-disk` | `boolean` | Track net disk consumption during reclaim via `Runner-Fetch`. | `true` |
| `monitor-disk-io` | `boolean` | Track disk I/O throughput (Read/Write MB) during deletion via `Runner-Fetch`. | `false` |
| `export-prometheus` | `boolean` | Export OpenMetrics (`metrics.prom`) telemetry via `Runner-Fetch`. | `false` |
| `sample-interval` | `integer` | Telemetry sampling interval in seconds. | `2` |

## Outputs

| Output | Type | Description | Example |
| - | - | - | - |
| `initial-free-bytes` | `integer` | Free space before reclamation in bytes. | `30064771072` |
| `final-free-bytes` | `integer` | Free space available for Nix in bytes. | `76241895424` |
| `reclaimed-bytes` | `integer` | Exact number of bytes freed by the action. | `46177124352` |

## Purged Bloat Catalog

### Linux Runners (`Ubuntu`)

- `/opt/hostedtoolcache` (Pre-installed Python, Ruby, Go, Node, Java, PHP versions)
- `/usr/local/lib/android` (Android SDK, NDK, platforms, system images)
- `/usr/local/share/boost` (Boost C++ libraries)
- `/usr/share/dotnet` (.NET SDKs, runtimes, templates)
- `/usr/share/swift` (Swift toolchains)
- `/var/lib/docker` & `/var/run/docker.sock` (Docker daemon and cached images)
- `/opt/ghc` & `/usr/local/.ghcup` (GHC, Cabal, Stack Haskell toolchains)
- `/opt/google/chrome` & `/opt/microsoft/msedge` & `/usr/lib/firefox` (Browsers and drivers)
- `/usr/share/man` & `/usr/share/doc` (Manpages and system documentation)

### macOS Runners (`Darwin`)

- `/Applications/Xcode*.app` (All multi-gigabyte Xcode bundles)
- `/Library/Developer/CoreSimulator` (Simulator runtimes)
- `/Users/runner/Library/Android` (Android SDK and build tools)
- `/Users/runner/hostedtoolcache` (Toolcache runtimes)
- `/opt/homebrew` & `/usr/local/Homebrew` (Homebrew package manager trees and caches)
- `/usr/local/share/dotnet` (.NET runtimes)
- `/Users/runner/Library/Caches` & `/Library/Caches` (System and user build caches)
