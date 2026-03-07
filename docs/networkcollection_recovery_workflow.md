# Network Collection PCAP Recovery Workflow
## Rocky Linux 10 | Scalpel 2.1 | Forensic Data Recovery

This document covers the full workflow for recovering PCAP capture data
from a network capture appliance using a Rocky Linux 10 workstation.

---

## Prerequisites

- Rocky Linux 10 workstation (this machine) with Scalpel installed
- SSH access to the Network Collection appliance (root or equivalent)
- Sufficient local storage for samples (at minimum 10GB free; more for full recovery)
- `tmux` installed for long-running transfers

---

## Phase 1: Prepare a tmux Session

All transfers should run inside tmux to survive SSH disconnections.

```bash
tmux new -s recovery
# To reattach if disconnected:
tmux attach -t recovery
```

---

## Phase 2: Identify the Storage Device on the network_collection_device

```bash
# Test basic connectivity
ssh root@<network_collection_device_ip> "echo OK"

# If connection is refused (old SSH daemon on appliance):
ssh network_collection_device root@<network_collection_device_ip> "echo OK"

# List block devices on the appliance
ssh root@<network_collection_device> "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT"

# Check disk usage
ssh root@<network_collection_device_ip> "df -h"
```

Look for the largest partition — typically `/dev/sdb1`, `/dev/sdc1`, or `/dev/md0`.
Note the device path — this is used as `if=` in the dd command.

---

## Phase 3: Extract a 1GB Sample

Start with 1GB to validate the approach before committing to a full transfer.

```bash
# With live progress bar (recommended)
ssh root@<network_collection_device> \
    "dd if=/dev/sdb1 bs=1M count=1024 status=none" \
    | pv -s 1073741824 \
    > /opt/nicks/samples/network_collection_device.dd

# Without pv
ssh root@<network_collection_device> \
    "dd if=/dev/sdb1 bs=1M count=1024" \
    > /opt/nicks/samples/network_collection_device.dd

# Verify
ls -lh /opt/nicks/samples/network_collection_device.dd
# Expected: approximately 1.0G
```

---

## Phase 4: Scan for PCAP Magic Bytes

Before carving, confirm PCAP data is present in the sample.

```bash
# Search for big-endian PCAP magic (standard libpcap)
xxd /opt/nicks/samples/network_collection_device.dd | grep -m 10 "a1b2 c3d4"

# Search for little-endian PCAP magic (some appliance formats)
xxd /opt/nicks/samples/network_collection_device.dd | grep -m 10 "d4c3 b2a1"
```

If neither produces output, either:
- The 1GB sample didn't land on PCAP data — try sampling from a different offset
- The data uses a different storage format — inspect with hexedit for patterns

**Sampling from a different offset:**
```bash
# Skip the first 10GB, sample the next 1GB
ssh root@<network_collection_device_ip> \
    "dd if=/dev/sdb1 bs=1M skip=10240 count=1024 status=none" \
    | pv -s 1073741824 \
    > /opt/nicks/samples/network_collection_device10g.dd
```

**Interactive hex inspection:**
```bash
hexedit /opt/nicks/samples/network_collection_device.dd
# Ctrl+S → search hex → type: a1b2c3d4 → Enter
# Ctrl+S → search hex → type: d4c3b2a1 → Enter
```

---

## Phase 5: Carve PCAP Files with Scalpel

```bash
# IMPORTANT: The output directory must NOT already exist
scalpel \
    /opt/nicks/samples/network_collection_device.dd \
    -o /opt/nicks/recovery_output

# Check results
ls -lh /opt/nicks/recovery_output/pcap*/

# Count carved files
ls /opt/nicks/recovery_output/pcap*/ | wc -l
```

**To re-run scalpel** (output dir must be removed first):
```bash
rm -rf /opt/nicks/recovery_output
scalpel /opt/nicks/samples/network_collection_device.dd \
    -o /opt/nicks/recovery_output
```

---

## Phase 6: Validate and Inspect Carved Files

```bash
# Check if a carved file is a valid PCAP
file /opt/nicks/recovery_output/pcap-0-0.pcap

# Quick packet summary
tshark -r /opt/nicks/recovery_output/pcap-0-0.pcap | head -50

# Protocol hierarchy
tshark -r /opt/nicks/recovery_output/pcap-0-0.pcap -q -z io,phs

# Traffic statistics
tshark -r /opt/nicks/recovery_output/pcap-0-0.pcap -q -z io,stat,0

# Batch validate all carved pcap files
for f in /opt/nicks/recovery_output/pcap*/*.pcap; do
    result=$(file "$f" | grep -o "tcpdump\|pcap\|capture" || echo "INVALID")
    echo "$result : $f"
done
```

---

## Phase 7: Scale Up to Full Recovery

Once PCAP data is confirmed in the sample, scale to the full device.

```bash
# Always do this inside tmux
tmux new -s full_recovery

# Full device transfer with progress and log
ssh root@<network_collection_device> \
    "dd if=/dev/sdb1 bs=1M status=none" \
    | pv \
    | tee /opt/nicks/samples/full_recovery.dd \
    > /opt/nicks/logs/transfer_$(date +%Y%m%d_%H%M%S).log

# Then carve the full image
scalpel \
    /opt/nicks/samples/full_recovery.dd \
    -o /opt/nicks/recovery_output_full
```

**Count reference for dd:**

| Sample size | count value |
|---|---|
| 1 GB | `count=1024` |
| 10 GB | `count=10240` |
| 100 GB | `count=102400` |
| Full device | omit `count` entirely |

---

## Troubleshooting

**Scalpel not found:**
```bash
export PATH="/usr/local/bin:$PATH"
# Add permanently:
echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.bashrc
```

**libtre not found error:**
```bash
sudo ldconfig
# Or:
export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
```

**SSH connection refused (old network_collection_device appliance):**
```bash
# Use the legacy host alias (set up by the workstation prep script)
ssh network_collection_device root@<network_collection_device>
```

**Scalpel output directory already exists:**
```bash
rm -rf /opt/nicks/recovery_output
# Then re-run scalpel
```

**No PCAP magic bytes found in sample:**
- Try a different offset (see Phase 4 above)
- The network_collection_device may store data in a proprietary format — inspect raw bytes with hexedit
- Check if data is compressed or encrypted

---

## Tool Locations (Rocky Linux 10.1)

| Tool | Path |
|---|---|
| scalpel | `/usr/local/bin/scalpel` |
| scalpel.conf | `/etc/scalpel/scalpel.conf` |
| libtre | `/usr/local/lib/libtre.so.5.0.0` |
| tshark | `/usr/bin/tshark` |
| xxd | `/usr/bin/xxd` |
| hexedit | `/usr/bin/hexedit` |
| pv | `/usr/bin/pv` |
| tmux | `/usr/bin/tmux` |
| dd | `/usr/bin/dd` |
| ssh | `/usr/bin/ssh` |
