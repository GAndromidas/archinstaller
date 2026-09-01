<div align="center">

# 🏗️ Archinstaller

**Turn a fresh Arch Linux base into a fully configured, optimized system — automatically.**

[![Platform](https://img.shields.io/badge/Platform-Arch%20Linux-1793E1?style=for-the-badge&logo=arch-linux)](https://archlinux.org/)
[![GitHub release](https://img.shields.io/github/release/GAndromidas/archinstaller.svg?style=for-the-badge&logo=github)](https://github.com/GAndromidas/archinstaller/releases)
[![Last Commit](https://img.shields.io/github/last-commit/GAndromidas/archinstaller.svg?style=for-the-badge&logo=git)](https://github.com/GAndromidas/archinstaller/commits/main)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![Stars](https://img.shields.io/github/stars/GAndromidas/archinstaller.svg?style=for-the-badge&logo=star)](https://github.com/GAndromidas/archinstaller/stargazers)

[Quick Start](#quick-start) · [Features](#features) · [Modes](#installation-modes) · [Customization](#customization) · [Troubleshooting](#troubleshooting)

</div>

---

## What is this?

Archinstaller is a **post-installation automation tool** for Arch Linux. It detects your hardware (CPU, GPU, storage, desktop environment) and applies **targeted optimizations** instead of one-size-fits-all settings — then sets up your shell, programs, firewall, and services through a clean, wizard-style dashboard.

It's designed around the Arch philosophy: **simple, transparent, and under your control.** The whole 10-step process can resume after an interruption, and every action is logged.

---

## ✨ Features

### System Intelligence
- **Hardware-aware detection** — CPU vendor, GPU type, storage type (NVMe/SSD/HDD), laptop vs desktop
- **Bootloader detection** — automatically configures GRUB, systemd-boot, or Limine
- **VM-friendly** — virtualized GPUs (QXL/virtio/VMware) get the right lightweight drivers for testing in gnome-boxes & friends
- **Desktop detection** — KDE Plasma 6+, GNOME 46+, and Cosmic get tailored packages & tweaks

### Performance
- **I/O scheduling** tuned per storage type (NVMe: `none`, SSD: `mq-deadline`, HDD: `bfq`) with persistent udev rules
- **Smart memory management** — swappiness adjusted to your RAM
- **Fixed fast downloads** — pacman `ParallelDownloads = 10`
- **Automatic microcode** — `intel-ucode` / `amd-ucode` for your CPU
- **Kernel headers** installed for every kernel you've got
- **Laptop optimizations** for 15+ manufacturers (power, thermals, function keys)

### Security (on by default)
- **Firewall** — UFW on Arch, firewalld on EndeavourOS (deny-incoming by default)
- **Fail2ban** — SSH brute-force protection reading from the systemd journal, with the ban action matched to your firewall
- **SSH allowed automatically**; KDE Connect ports opened when detected
- **User groups** — `wheel`, `video`, `storage`, `optical`, `scanner`, `lp`, `rfkill`

### Optional Extras
- **Gaming Mode** — Steam, Wine, GameMode, MangoHud, Discord, Heroic & more (with multilib enabled)
- **Wake-on-LAN** — persistent, multi-adapter WoL for desktops (auto-skipped on laptops/VMs)
- **Server mode** — Docker, sysctl tuning, and time sync for headless boxes

---

## Installation Modes

| Mode | Best for | What you get |
|------|----------|--------------|
| **Standard** | Full desktop use | Complete DE + apps, all optimizations |
| **Minimal** | Lightweight / low-spec | Essentials only, less bloat |
| **Server** | Headless boxes | Docker, sysctl tuning, **interactive** Portainer & Watchtower setup |

> **Gaming Mode** is offered as an optional add-on during Standard or Minimal installs.

---

## Quick Start

### Prerequisites
- A fresh Arch Linux install (minimal base system)
- An active internet connection
- A user account with `sudo` privileges
- At least 2 GB free disk space

### Run it

```bash
git clone https://github.com/GAndromidas/archinstaller.git
cd archinstaller
./install.sh
```

You'll pick your mode from an interactive menu (or type ahead with options):

```bash
./install.sh --verbose   # Detailed package output
./install.sh --quiet     # Minimal output
./install.sh --dry-run   # Preview changes without making any
```

> **Server mode** is selected from the menu (or auto-selected on headless systems). There is no `--server` flag.

### What it does for you
The installer runs through 10 steps and tracks its own progress, so an interrupted install can **resume where it left off**:

| # | Step | What happens |
|---|------|--------------|
| 1 | System Preparation | pacman tuning, mirror ranking, full update, microcode, kernels, locales |
| 2 | Shell Setup | Zsh + Oh-My-Zsh + Starship + Fastfetch (never overwrites existing config) |
| 3 | Yay Installation | AUR helper for community packages |
| 4 | Programs | Mode- & DE-specific apps from YAML |
| 5 | Gaming Mode | Optional gaming stack |
| 6 | Bootloader | Kernel params for GRUB / systemd-boot / Limine |
| 7 | System Services | Firewall, GPU drivers, power & storage tuning |
| 8 | Fail2ban | SSH hardening |
| 9 | Wake-on-LAN | Desktops only |
| 10 | Maintenance | Cache/package cleanup |

---

## Customization

You don't need to touch the scripts to change what gets installed. Everything lives in **YAML config files**.

### Package lists
Open [`configs/programs.yaml`](configs/programs.yaml) and add/remove packages from any section:

```yaml
pacman:      # Core packages (all modes)
essential:   # Mode-specific packages
desktop_environments:  # DE-specific packages
aur:         # AUR packages
flatpak:     # Flatpak apps
```

Gaming packages live in [`configs/gaming_mode.yaml`](configs/gaming_mode.yaml).

### Other config files
| File | Purpose |
|------|---------|
| `.zshrc` | Zsh shell configuration (Oh-My-Zsh) |
| `starship.toml` | Starship prompt theme |
| `config.jsonc` | Fastfetch system-info display |
| `MangoHud.conf` | Gaming overlay config |

---

## Hardware Support

| Component | Supported |
|-----------|-----------|
| **CPU** | Intel & AMD (microcode + tuning) |
| **GPU** | AMD, Intel, NVIDIA, plus VM (QXL/virtio/VMware) |
| **Storage** | NVMe, SSD, HDD |
| **Form factor** | Desktop, Laptop, VM |
| **Laptops** | 15+ brands with manufacturer-specific setups |
| **Bootloaders** | GRUB, systemd-boot, Limine |
| **Desktops** | KDE Plasma 6+, GNOME 46+, Cosmic |

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Install interrupted | Re-run `./install.sh` — it resumes from the saved state |
| No internet | Check `ping archlinux.org`, then re-run |
| Package install failure | Check the install log below |
| Not enough disk space | Free 2 GB+ and retry |

### Logs & state
```bash
/tmp/archinstaller.log     # Full installation log
/tmp/archinstaller.state   # Progress/resume tracking
```

> Logs live in `/tmp`, so they're cleared on reboot. The installer offers manual cleanup at the end.

---

## Contributing

Contributions are welcome! To keep things clean:

1. Fork the repo and create a branch (`git checkout -b feature/my-feature`)
2. Keep changes focused and well-tested
3. Open a pull request describing what & why

Found a bug or want a feature? [Open an issue](https://github.com/GAndromidas/archinstaller/issues).

---

## Project Status

| Area | Status |
|------|--------|
| Core installer | Production ready |
| Hardware detection | Stable |
| Security hardening | Active & on by default |
| Gaming mode | Tested |
| Server mode | Production ready |
| Resume / logging | Working |

---

## License

MIT — see the [LICENSE](LICENSE) file.

You're free to use, modify, and distribute this for personal or commercial purposes.

---

<div align="center">

Built for the Arch Linux community. If this saved you time, consider giving it a ⭐

</div>
