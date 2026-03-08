# scalpel-rocky10

**Scalpel 2.1 for Rocky Linux 10 (Red Quartz) — Pre-built Binary + Full Build Guide**

Scalpel is a fast file carver that recovers files from disk images based on header/footer
magic bytes. It is the actively maintained successor to `foremost`.

**The problem:** Scalpel has no package in any Rocky Linux 10 repository (BaseOS,
AppStream, EPEL). `foremost` is also unavailable for el10. Both must be built from
source, which requires patching Scalpel's source code for C++17 compatibility and
building its `libtre` dependency from source as well.

This repo provides:
- A pre-built binary release (x86-64-v3, Rocky Linux 10.1)
- The `libtre 0.8.0` shared library it depends on
- A one-command install script
- A fully documented build-from-source script with all patches applied
- PCAP-ready `scalpel.conf` with big-endian and little-endian magic byte rules

---

## Quick Install (Pre-built Binary)

> **Requirements:** Rocky Linux 10, x86_64, x86-64-v3 CPU (AVX2)

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/scalpel-rocky10.git
cd scalpel-rocky10

# Run the installer (installs binary + libtre + config)
sudo bash scripts/install_prebuilt.sh

# Verify
scalpel 2>&1 | head -3
```

---

## Build From Source

If you prefer to compile yourself (recommended for production or non-x86_64):

```bash
git clone https://github.com/YOUR_USERNAME/scalpel-rocky10.git
cd scalpel-rocky10
sudo bash scripts/build_from_source.sh
```

This script handles everything:
- Installs all build dependencies via dnf
- Downloads and builds libtre 0.8.0 from source
- Clones scalpel 2.1 from GitHub
- Applies all C++17 compatibility patches
- Compiles and installs scalpel
- Installs and configures scalpel.conf with PCAP rules

---

## Pre-built Binary Details

| Item | Value |
|---|---|
| Scalpel version | 2.1 |
| Built on | Rocky Linux 10.1 (Red Quartz) |
| Architecture | x86_64 (x86-64-v3 / AVX2) |
| Compiler | GCC 14.3.1 (Red Hat 14.3.1-2) |
| libtre version | 0.8.0 |
| Build date | 2026-03-06 |
| scalpel SHA256 | `1179ffa678ced34028d8dde7320ea1e361885629aed6b8fad16625842c1d9181` |
| libtre SHA256 | `6a6debff50ffac64a64ccc9dbdf86b4d63542eddfc0ea8141b3e61faeb1a735b` |

---

## Usage

### Carve PCAP files from a raw disk image

```bash
# Basic carve — output dir must NOT already exist
scalpel disk_sample.dd -o recovery_output/

# Check what was found
ls -lh recovery_output/pcap*/

# Validate a carved file
file recovery_output/pcap-0-0.pcap

# Inspect with tshark
tshark -r recovery_output/pcap-0-0.pcap | head -50
```

### PCAP magic bytes reference

| Endianness | Magic bytes | Use case |
|---|---|---|
| Big-endian | `a1 b2 c3 d4` | Standard libpcap / tcpdump |
| Little-endian | `d4 c3 b2 a1` | Modified libpcap, some Niksun formats |

Both rules are active in the included `scalpel.conf`.

---

## Context: Niksun PCAP Recovery

This package was originally developed to support forensic recovery of PCAP data
from Niksun network capture appliances running large (100TB+) raw storage volumes.

Full workflow documentation is included in `docs/niksun_recovery_workflow.md`.

---

## Repository Structure

```
scalpel-rocky10/
├── README.md
├── bin/
│   └── scalpel                  # Pre-built binary (x86_64, RL10.1)
├── lib/
│   ├── libtre.so.5.0.0          # libtre shared library (built from source)
│   ├── libtre.so.5 -> libtre.so.5.0.0
│   └── libtre.so   -> libtre.so.5.0.0
├── config/
│   └── scalpel.conf             # Full config with PCAP rules enabled
├── scripts/
│   ├── install_prebuilt.sh      # One-command install from this repo
│   ├── build_from_source.sh     # Full source build script
│   └── scalpel_fix.sh           # C++17 patch script (used by build script)
└── docs/
    └── network_collection_workflow.md
```

---

## Compatibility Notes

- Built and tested on **Rocky Linux 10.1 x86_64**
- Requires x86-64-v3 microarchitecture (AVX2) — Rocky Linux 10 dropped v2 support
- The pre-built binary will **not** work on Rocky Linux 9 or earlier (different glibc)
- For other RHEL 10 derivatives (AlmaLinux 10, etc.) the binary should work;
  use `build_from_source.sh` if it doesn't
- `foremost` is not included — it has no el10 package and is unmaintained

---

## License

Scalpel is licensed under the Apache License 2.0.
libtre is licensed under the LGPL.
Scripts in this repository are released under MIT License.
