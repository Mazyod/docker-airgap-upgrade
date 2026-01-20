# Docker Engine 28.5.1 → 29.1.5 Upgrade for Air-Gapped RHEL 8/9

This package contains scripts for upgrading Docker Engine from 28.5.1 to 29.1.5 on air-gapped RHEL 8 and RHEL 9 servers.

## Why This Upgrade?

Docker 29.1.x fixes **external DNS resolution on all custom bridge networks** ([moby/moby#51615](https://github.com/moby/moby/pull/51615)).

## Critical Information

### You Cannot Upgrade docker-ce Alone

Docker 29.x **requires** containerd.io 2.2.x (up from 1.7.x in Docker 28.x). This is a major dependency upgrade.

| Docker Version | containerd.io Version |
|----------------|----------------------|
| 28.5.1 | 1.7.29 |
| **29.1.5** | **2.2.1** |

### Package Name Clarification

```
WRONG: containerd (standalone package)
RIGHT: containerd.io (Docker's bundled containerd)
```

## Scripts Overview

| Script | Purpose | Run On |
|--------|---------|--------|
| `simulate-upgrade.sh` | Test upgrade path in a VM | UTM/RHEL test VM |
| `download-docker-packages.sh` | Download all packages | Online RHEL server |
| `upgrade-docker.sh` | Perform the upgrade | Air-gapped servers |
| `recover-dnf.sh` | Fix dependency issues | Servers with broken dnf |
| `rollback-docker.sh` | Emergency rollback | Failed upgrade recovery |

## Usage

### Step 1: Simulation (Recommended)

Test the upgrade path in a VM first:

1. Create a RHEL 8 VM in UTM (use emulation for x86_64 on Apple Silicon)
2. Copy `simulate-upgrade.sh` to the VM
3. Run: `chmod +x simulate-upgrade.sh && ./simulate-upgrade.sh`

### Step 2: Download Packages (Online Server)

On an online RHEL server:

```bash
chmod +x download-docker-packages.sh
./download-docker-packages.sh
```

This creates `/opt/docker-offline-packages.tar.gz` containing:
- Docker 29.1.5 packages for RHEL 8 and 9
- Rollback packages (28.5.1)
- NVIDIA Container Toolkit packages (for GPU servers)

### Step 3: Transfer to Air-Gapped Servers

Transfer `docker-offline-packages.tar.gz` via USB or secure transfer.

### Step 4: Upgrade Each Server

On each air-gapped server:

```bash
# Extract packages
tar xzvf docker-offline-packages.tar.gz -C /opt/

# For Swarm nodes: drain first
docker node update --availability drain <node-name>

# Run upgrade
chmod +x upgrade-docker.sh
./upgrade-docker.sh

# For Swarm nodes: make active again
docker node update --availability active <node-name>
```

### If Something Goes Wrong

**Dependency issues:**
```bash
chmod +x recover-dnf.sh
./recover-dnf.sh
```

**Need to rollback:**
```bash
chmod +x rollback-docker.sh
./rollback-docker.sh
```

## Key Learnings (From Past Experience)

| Issue | Solution |
|-------|----------|
| `dnf upgrade` does nothing | Two-phase: `install` then `distro-sync --allowerasing` |
| containerd vs containerd.io confusion | Always use `containerd.io` package |
| Service startup failures | Start containerd FIRST, wait, then docker |
| gRPC/ALPN handshake errors | Upgrade ALL cluster nodes together |

## Breaking Changes in containerd 2.x

- Config format changed: Run `containerd config migrate` (handled by scripts)
- gRPC API incompatible with 1.7.x: Upgrade all nodes together
- Minimum Docker API v1.44: Ensure clients are v25.0+

## Directory Structure After Download

```
/opt/docker-offline/
├── rhel8/              # Docker 29.1.5 for RHEL 8
├── rhel9/              # Docker 29.1.5 for RHEL 9
├── rollback-rhel8/     # Docker 28.5.1 for RHEL 8
├── rollback-rhel9/     # Docker 28.5.1 for RHEL 9
└── nvidia/             # NVIDIA Container Toolkit
```

## Verification

After upgrade, verify:

```bash
# Check versions
docker version          # Should show 29.1.5
containerd --version    # Should show 2.2.1

# Check packages
rpm -q docker-ce docker-ce-cli containerd.io

# Test DNS on custom bridge (the bug fix)
docker network create test-net
docker run --rm --network test-net alpine nslookup google.com
docker network rm test-net
```

## Sources

- [Docker Engine RHEL Install Docs](https://docs.docker.com/engine/install/rhel/)
- [Docker Engine v29 Release Notes](https://docs.docker.com/engine/release-notes/29/)
- [containerd Releases](https://containerd.io/releases/)
- [NVIDIA Container Toolkit Install Guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
