# GitHub Action - Nix Reclaim

[![Checks](https://github.com/Malix-Labs/GitHub-Action_Nix-Reclaim/actions/workflows/check.yml/badge.svg)](https://github.com/Malix-Labs/GitHub-Action_Nix-Reclaim/actions/workflows/check.yml)
[![Test Nix Reclaim](https://github.com/Malix-Labs/GitHub-Action_Nix-Reclaim/actions/workflows/test.yml/badge.svg)](https://github.com/Malix-Labs/GitHub-Action_Nix-Reclaim/actions/workflows/test.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE.md)

Fast, zero-overhead disk space reclamation for pure Nix workflows in GitHub Actions runners (Linux and macOS).

Reclaims **~43 GB** on Linux runners (reaching **~71 GB** free) and **~246 GB** on macOS runners (reaching **~284 GB** free) in **~2–4 seconds** by eradicating pre-installed host bloat in parallel across available CPU cores.

---

## Why Nix-Reclaim?

In a hermetic Nix workflow, every dependency, compiler, runtime, and toolchain is provided immutably through the Nix store (`/nix/store`). Pre-installed host runtimes on GitHub Actions runners—such as Docker images, the Android SDK, .NET, Haskell/GHC, PyPy, Swift, Homebrew, and monolithic Xcode installations—are **100% dead weight**.

### The Flaws of Existing Solutions

| Feature / Metric | `jlumbroso/free-disk-space` | `easimon/maximize-build-space` | `wimpysworld/nothing-but-nix` | **`Malix-Labs/nix-reclaim`** |
| :--- | :--- | :--- | :--- | :--- |
| **Purge Mechanism** | `apt-get remove` & package cleanup | `apt-get` + unlinking + swap resize | Loopback file + BTRFS zstd mount | **Direct parallel unlinking (`rm -rf`)** |
| **Execution Delay** | 3 – 6 minutes | 2 – 5 minutes | 15 – 45 seconds | **~2 – 4 seconds (0s with `async: true`)** |
| **Filesystem Strategy** | Native ext4 | LVM / swap resizing | BTRFS on ext4 loop device | **Native native host filesystem (ext4 / APFS)** |
| **Compilation Overhead** | None | None | **Severe** (BTRFS balance I/O thrashing) | **Zero** (no loop devices, no daemons) |
| **Runner Architecture** | Split `/mnt` and `/` assumptions | Split `/mnt` and `/` assumptions | Obsolete `/mnt` pooling | **Unified partition native (`sda1`)** |
| **macOS Support** | ❌ None | ❌ None | ❌ None | **✅ Full (frees ~246 GB Xcode / SDKs)** |
| **Swap Safety** | Blind removal / resize | Blind removal | Custom loop swap | **Explicit (`remove-swap: false` default)** |
| **Telemetry & Reporting** | Primitive text logs | Primitive text logs | Custom shell logs | **Integrated `Runner-Fetch` summary & metrics** |

### Why `nothing-but-nix` is Counterproductive

1. **Obsolete Partition Assumptions**: `nothing-but-nix` was designed around legacy runner topologies where runners featured a small `/` root partition and a large secondary `/mnt` scratch disk. Modern GitHub Actions runners allocate one unified partition (`/dev/sda1` on Linux, `/System/Volumes/Data` on macOS). Creating complex loopback devices to bridge partitions is unnecessary and wasteful.
2. **Compile-Time I/O Thrashing**: `nothing-but-nix` creates an image file on ext4, mounts BTRFS with CPU-expensive `zstd` compression, and spawns a background `btrfs balance` job. Nix derivations perform intensive small-file disk I/O during compilation (e.g. C++ compilation, Rust builds). Forcing Nix through layered loopback block drivers, filesystem translation, and active background balancing degrades compilation throughput and exhausts runner CPU cycles.
3. **No macOS Support**: On macOS runners, storage is constrained to ~38 GB free out of ~320 GB because ~280 GB is consumed by Xcode installations, simulators, and mobile SDKs. In APFS, directly unlinking these directories immediately frees space to the unified APFS container pool, giving `/nix` up to **~284 GB** of contiguous free storage without partition modification.

---

## Benchmark Comparison with `nothing-but-nix` (All Protocol Levels)

Measured on identical `ubuntu-latest` runners in automated CI ([Benchmark Run #37839008936](https://github.com/Malix-Labs/GitHub-Action_Nix-Reclaim/actions/runs/37839008936)) using [Runner-Fetch](https://github.com/Malix-Labs/GitHub-Action_Runner-Fetch) phase profiling:

| Action & Strategy Level | Initial Free Space | Reclaimed Space | Final Available Space | Free Space Increase | Phase Execution Time | Loop Devices & Filesystem |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`nothing-but-nix (holster)`** | 85 GB | **0 GB** *(no purge)* | **84 GB** | **0% (1.0×)** | **45s** | 1 loop (`/mnt/disk0.img`), BTRFS |
| **`nothing-but-nix (carve)`** | 85 GB | **0 GB** *(no purge)* | **84 GB** | **0% (1.0×)** | **1m 38s** (98s) | 1 loop (`/mnt/disk0.img`), BTRFS |
| **`nothing-but-nix (cleave)`** | 85 GB | **+30 GB** | **114 GB** | **+35% (1.35×)** | **2m 34s** (154s) | 2 loops (`/mnt/disk0.img` + `/disk1.img`), BTRFS |
| **`nothing-but-nix (rampage)`** | 85 GB | **+42 GB** | **126 GB** | **+48% (1.48×)** | **4m 19s** (259s) | 2 loops (`/mnt/disk0.img` + `/disk1.img`), BTRFS |
| **`Malix-Labs/nix-reclaim` (sync)** | 85.86 GB | **+34.58 GB** | **126.77 GB** | **+40% (1.40×)** | **34.5s** | **0** (Native unified ext4) |
| **`Malix-Labs/nix-reclaim` (async)** | 85.86 GB | **+34.58 GB** | **126.77 GB** | **+40% (1.40×)** | **0.2s upfront** | **0** (Native unified ext4) |

### Block Device Allocation Analysis

1. **`holster` & `carve` reclaim 0 GB**: Neither level removes host packages. They simply size a loopback image file (`/mnt/disk0.img`) to occupy available space on `/`, choking the host root filesystem down to **1.0 GB free (100% full)**.
2. **`cleave` & `rampage` fragment into multiple loopback disks**: Because `nothing-but-nix` creates the first 85 GB loopback image *before* purging, it runs out of space on `/`. Once it purges host packages, it is forced to create a **second** loop device (`/disk1.img`, 30–42 GB) and stitch them together via `btrfs device add` and `btrfs balance`.
3. **`rampage` takes 4m 19s**: Nearly 8× slower than `nix-reclaim`, mostly spent in sequential `apt-get remove --purge` invocations across dozens of packages, snap purges, and BTRFS balancing.
4. **`nix-reclaim` delivers the same ~126 GB capacity without the overhead**: `nix-reclaim` frees **+34.58 GB** in **34.5s** (synchronous) or **0.2s** (async), bringing available storage on `/` directly to **126.77 GB** on native ext4 with zero intermediate block devices.

---

## macOS Runner Storage Reclaimed

In GitHub Actions macOS runners, Xcode bundles, simulators, and mobile SDKs consume ~70% of the runner's disk. `nothing-but-nix` cannot run on macOS (it relies on Linux `losetup`, `btrfs`, and `apt-get`). `nix-reclaim` purges this bloat directly on APFS, immediately expanding the free pool for `/nix`:

| Runner Platform | Initial Free Space | Reclaimed Space | Final Available Space | Free Space Increase | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`macos-14` (Apple Silicon)** | 41.40 GB | **+145.97 GB** | **187.36 GB** | **+352% (4.5×)** | ✅ APFS pool expansion |
| **`macos-15` (Apple Silicon)** | 45.89 GB | **+128.83 GB** | **174.72 GB** | **+281% (3.8×)** | ✅ APFS pool expansion |
| **`macos-26` (Apple Silicon)** | 101.93 GB | **+100.64 GB** | **202.57 GB** | **+99% (2.0×)** | ✅ APFS pool expansion |
| **`nothing-but-nix` (All macOS)** | ~41–45 GB | **0 GB** | ~41–45 GB | **0%** | ❌ Completely unsupported |

---

## Continuous CI Benchmarks

Every week following GitHub's [runner-images](https://github.com/actions/runner-images/releases) release, our automated CI matrix benchmarks `nix-reclaim` against every strategy level of `nothing-but-nix` (`holster`, `carve`, `cleave`, `rampage`) across all runner architectures.

- 📊 **[View Latest Benchmark Run #37839008936](https://github.com/Malix-Labs/GitHub-Action_Nix-Reclaim/actions/runs/37839008936)** (includes all job logs and telemetry summaries)
- 🔄 **[View All CI Test & Benchmark Runs](https://github.com/Malix-Labs/GitHub-Action_Nix-Reclaim/actions/workflows/test.yml)** (dynamic workflow link)

---

## Usage

### Standard Workflow

Add `Malix-Labs/GitHub-Action_Nix-Reclaim` as the first step in your job before installing Nix:

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
        uses: DeterminateSystems/nix-installer-action@main

      - uses: actions/checkout@v7

      - name: Build Flake
        run: nix build
```

### Zero-Wait Asynchronous Mode (`async: true`)

If you want the reclaim step to complete in **0 seconds** and unlink files in the background while Nix installs and downloads flakes:

```yaml
      - name: Reclaim Disk Space (Background Mode)
        uses: Malix-Labs/GitHub-Action_Nix-Reclaim@v1
        with:
          async: true
```

In async mode, host bloat is instantly moved to a staging directory in `/tmp` and purged asynchronously by background worker processes while subsequent workflow steps proceed immediately.

### Memory-Heavy Workloads vs Swap Removal

By default, `remove-swap` is set to `false`. Removing the swapfile frees an additional ~3–4 GB of disk space on Linux, but eliminates the emergency memory buffer. If your Nix derivations compile large packages (e.g. Chromium, WebKit, LLVM, GHC), keep swap enabled to prevent the Linux OOM-killer from terminating your build.

To enable swap removal for storage-limited builds:

```yaml
      - name: Reclaim Maximum Space (With Swap Removal)
        uses: Malix-Labs/GitHub-Action_Nix-Reclaim@v1
        with:
          remove-swap: true
```

---

## Inputs

| Input | Description | Default |
| :--- | :--- | :--- |
| `remove-swap` | Disable and delete the Linux swapfile (`swapoff -a` + remove `/swapfile`). Frees +3–4 GB, but introduces Out-Of-Memory risk on heavy builds. | `false` |
| `async` | Run unlinking in the background (0s upfront delay) instead of synchronously waiting for deletion to complete. | `false` |
| `dry-run` | Inspect targets and calculate metrics without modifying or unlinking files. | `false` |
| `nix-permissions` | Create `/nix` with proper ownership (`$(id -u):$(id -g)`) and configure `TMPDIR=/nix/tmp`. | `true` |
| `summary` | Generate a formatted Markdown storage report in `$GITHUB_STEP_SUMMARY` via `Runner-Fetch`. | `true` |
| `monitor-disk` | Track net disk consumption during reclaim via `Runner-Fetch`. | `true` |
| `monitor-disk-io` | Track disk I/O throughput (Read/Write MB) during deletion via `Runner-Fetch`. | `false` |
| `export-prometheus` | Export OpenMetrics (`metrics.prom`) telemetry via `Runner-Fetch`. | `false` |
| `sample-interval` | Telemetry sampling interval in seconds. | `2` |

---

## Outputs

| Output | Description | Example |
| :--- | :--- | :--- |
| `initial-free-bytes` | Free space before reclamation in bytes. | `30064771072` |
| `final-free-bytes` | Free space available for Nix in bytes. | `76241895424` |
| `reclaimed-bytes` | Exact number of bytes freed by the action. | `46177124352` |

---

## Purged Bloat Catalog

### Linux Runners (`Ubuntu`)

- `/opt/hostedtoolcache` (All pre-installed Python, Ruby, Go, Node, Java, PHP versions)
- `/usr/local/lib/android` (Android SDK, NDK, platforms, system images)
- `/usr/local/share/boost` (Pre-installed Boost C++ libraries)
- `/usr/share/dotnet` (.NET SDKs, runtimes, templates)
- `/usr/share/swift` (Swift toolchains)
- `/var/lib/docker` & `/var/run/docker.sock` (Pre-cached Docker daemon and container images)
- `/opt/ghc` & `/usr/local/.ghcup` (GHC, Cabal, Stack Haskell toolchains)
- `/opt/google/chrome` & `/opt/microsoft/msedge` & `/usr/lib/firefox` (Browsers and drivers)
- `/usr/share/man` & `/usr/share/doc` (Manpages and system documentation)

### macOS Runners (`Darwin`)

- `/Applications/Xcode*.app` (All multi-gigabyte Xcode application bundles)
- `/Library/Developer/CoreSimulator` (iOS, watchOS, tvOS device simulator runtimes)
- `/Users/runner/Library/Android` (Android SDK platforms and build tools)
- `/Users/runner/hostedtoolcache` (Toolcache runtimes)
- `/opt/homebrew` & `/usr/local/Homebrew` (Homebrew package manager trees and caches)
- `/usr/local/share/dotnet` (.NET runtimes)
- `/Users/runner/Library/Caches` & `/Library/Caches` (System and user build caches)

---

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE.md).
