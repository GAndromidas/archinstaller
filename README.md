<div align="center">

# Archinstaller

**Fresh Arch → ready-to-use in 10 steps. Hardware-aware, resumable, transparent.**

[![Arch Linux](https://img.shields.io/badge/Arch%20Linux-1793D1?style=for-the-badge&logo=arch-linux&logoColor=white)](https://archlinux.org)
[![Release](https://img.shields.io/github/v/release/GAndromidas/archinstaller?style=for-the-badge)](https://github.com/GAndromidas/archinstaller/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)

`post-install automation` · `hardware-aware` · `resumable` · `logged`

[Quick Start](#-quick-start) · [Features](#-features) · [Modes](#-modes) · [Customize](#-customize)

</div>

---

## ⚡ Quick Start

**Prereqs:** fresh Arch base, internet, `sudo` user, 2 GB free.

```bash
git clone https://github.com/GAndromidas/archinstaller.git
cd archinstaller
./install.sh
```

```bash
./install.sh --verbose   # detailed output
./install.sh --quiet     # minimal
./install.sh --dry-run   # preview only
```

> Re-run to resume — state in `/var/tmp/archinstaller.state` survives reboots.

---

## 🎯 What it does

Detects your system (CPU, GPU, SSD/HDD/NVMe, laptop/desktop/VM, bootloader, DE) and applies **targeted optimizations** — not one-size-fits-all. 10-step wizard, every action logged to `/var/tmp/archinstaller.log`.

**Philosophy:** Simple, transparent, under your control. No hidden magic.

---

## ✨ Features

| Area | Highlights |
|------|------------|
| **System** | `700 /boot` (UKI) handled via `sudo` + atomic `/tmp` writes · dated `systemd-boot` `2026-09-04_10-49-12_linux.conf` smart patch · `loader.conf: timeout 3 / console-mode max` |
| **Performance** | I/O scheduler per storage (`none`/`mq-deadline`/`bfq` + udev) · swappiness by RAM · `ParallelDownloads=10` · `amd-ucode`/`intel-ucode` · kernel headers |
| **Bootloaders** | `systemd-boot` (UKI + dated entries) · `GRUB` · `Limine + Snapper` — auto-detected |
| **Snapshots** | `snapper` + `snap-pac` + `btrfs-assistant` universal (all bootloaders, not just Limine) · ArchWiki profile `Daily 1 / Boot 1 / others 0 / Number 8` + `QUARTERLY 0`, `snapper-timeline/cleanup/boot.timer` |
| **Security** | `UFW` (Arch) / `firewalld` (EndeavourOS) `deny incoming` · `Fail2ban` (systemd-journal, `ufw`/`firewalld` action) · `SSH` auto-allow · `KDE Connect`/`Portainer 8000/9443` deferred |
| **Desktop** | KDE 6+, GNOME 46+, Cosmic tailored · `Zsh + Oh-My-Zsh + Starship` (never overwrites) |
| **Extras** | Gaming (Steam/Wine/GameMode/MangoHud/LACT) · WoL (desktops, multi-NIC) · Server (Docker) |

---

## 🧭 Modes

| Mode | For | Gets you |
|------|-----|----------|
| **Standard** | Daily desktop | Full DE + apps + all tuning |
| **Minimal** | Low-spec / clean | Essentials only |
| **Server** | Headless | Docker + sysctl + Portainer/Watchtower |

`Gaming Mode` is an optional add-on for Standard/Minimal.

---

## 📋 10 Steps

| # | Step | Does |
|---|------|------|
| 1 | Preparation | pacman tune, `rate-mirrors`, full update, microcode, headers, locales |
| 2 | Shell | Zsh, Starship, Fastfetch |
| 3 | Yay | AUR helper |
| 4 | Programs | `programs.yaml` / `gaming_mode.yaml` (DE/mode-aware) |
| 5 | Gaming | Optional stack |
| 6 | Bootloader | Unified kernel params (`quiet`/`splash`/`amd_pstate`/`nvidia` etc.) for GRUB/systemd-boot/Limine |
| 7 | Services | Firewall, GPU drivers, power/storage/audio |
| 8 | Fail2ban | SSH hardening |
| 9 | WoL | Desktops only |
| 10 | Maintenance | Cache cleanup |

---

## 🔧 Customize

No script edits needed — edit YAML:

```yaml
# configs/programs.yaml
pacman: [git, curl]
essential: { default: [code], minimal: [nano] }
desktop_environments: { kde: [dolphin], gnome: [nautilus] }
aur: [yay]
flatpak: [com.spotify.Client]
```

| File | Purpose |
|------|---------|
| `configs/programs.yaml` | Packages |
| `configs/gaming_mode.yaml` | Gaming |
| `configs/.zshrc` | Zsh |
| `configs/starship.toml` | Prompt |
| `configs/MangoHud.conf` | Overlay |

---

## 🖥️ Hardware

`Intel/AMD` (µcode) · `AMD/Intel/NVIDIA + QXL/virtio/VMware` · `NVMe/SSD/HDD` · `Laptop 15+ brands` · `VM/headless` auto-detected · `UEFI/BIOS`

---

## 🆘 Troubleshooting

| Problem | Fix |
|---------|-----|
| Interrupted | `./install.sh` resumes |
| No internet | `ping 8.8.8.8` → check DNS/cable, re-run |
| Disk full | Free 2 GB+ |
| Log | `/var/tmp/archinstaller.log` + `.state` |

---

## 🤝 Contribute

```bash
git checkout -b feat/my-feature
# keep focused, test on VM
# PR with what & why
```

[Open an issue](https://github.com/GAndromidas/archinstaller/issues) for bugs/ideas.

---

<div align="center">

**MIT** — [LICENSE](LICENSE) · Built for Arch users. ⭐ if it saved you time.

</div>
