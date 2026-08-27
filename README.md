<div align="center">

# Archinstaller

[![GitHub release](https://img.shields.io/github/release/GAndromidas/archinstaller.svg?style=for-the-badge&logo=github)](https://github.com/GAndromidas/archinstaller/releases)
[![Last Commit](https://img.shields.io/github/last-commit/GAndromidas/archinstaller.svg?style=for-the-badge&logo=git)](https://github.com/GAndromidas/archinstaller/commits/main)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge&logo=open-source-initiative)](LICENSE)
[![Arch Linux](https://img.shields.io/badge/Platform-Arch%20Linux-1793E1?style=for-the-badge&logo=arch-linux)](https://archlinux.org/)
[![Stars](https://img.shields.io/github/stars/GAndromidas/archinstaller.svg?style=for-the-badge&logo=star)](https://github.com/GAndromidas/archinstaller/stargazers)

**Arch Linux Post-Installation Automation**

Transform your minimal Arch Linux installation into a fully configured, optimized system with intelligent hardware detection and tailored optimizations.

[Quick Start](#-quick-start) · [Features](#-key-features) · [Installation Modes](#-installation-modes) · [Configuration](#-customization)

</div>

---

## Overview

**Archinstaller** is a sophisticated post-installation automation tool that intelligently configures Arch Linux based on your hardware. It applies targeted optimizations rather than one-size-fits-all settings, ensuring optimal performance for your specific configuration.

### Core Philosophy

| Philosophy | Description |
|------------|-------------|
| **Hardware-Aware** | Detects CPU, GPU, storage, and desktop environment for tailored optimizations |
| **Security-First** | Comprehensive hardening enabled by default with firewall and fail2ban |
| **Performance-Optimized** | Intelligent I/O scheduling and kernel tuning for optimal responsiveness |
| **Reliable** | Resume functionality for interrupted installations with progress tracking |
| **Idempotent** | Re-running on an already-configured system is safe — no duplicates, no broken configs |
| **Update-Friendly** | `--force` re-applies updated defaults after you `git pull` the installer |

---

## Key Features

### System Intelligence & Automation

#### Hardware Detection
```yaml
CPU Detection:
  Intel: intel-ucode + microcode updates
  AMD: amd-ucode + microcode updates
  
GPU Detection:
  AMD: Open-source drivers + Vulkan (Vulkan RADV + lib32)
  Intel: Integrated graphics + Vulkan (ANV + lib32)
  NVIDIA: Optional proprietary drivers (opt-in, nvidia-open)
          with DRM kernel mode setting for Wayland
  
Storage Optimization:
  NVMe: none scheduler + trim optimizations
  SSD: mq-deadline scheduler + wear leveling
  HDD: bfq scheduler + readahead settings
  
Laptop Features:
  Manufacturer-specific optimizations (15+ brands)
  Gaming laptop detection + gaming features
  Power management + thermal throttling
  Battery optimization + suspend/resume
  Function keys + hotkeys support
```

#### Bootloader Detection & Configuration
| Bootloader | Features | Integration |
|------------|----------|-------------|
| **GRUB** | Timeout optimization, boot menu management | Automatic configuration |
| **systemd-boot** | EFI support, kernel fallback | Automatic entry management |
| **Limine** | Modern UEFI, fast boot support, bootable snapshot menu | Automatic entry generation for all installed kernels |

All bootloader configs are generated safely:
- Entries generated from every installed kernel (`/boot/vmlinuz-*`) — never a hardcoded list
- Config validated before replacing; backup kept and restored if generation fails
- Windows dual-boot auto-detected via EFI System partitions (works across drives) and added as a proper UEFI chainload entry

#### Advanced Performance Optimization (CachyOS-Inspired)

- **Smart Memory Management**: Dynamic swappiness based on system RAM (<4GB: 60, 4-8GB: 30, 8-16GB: 10, 16GB+: 1)
- **zRAM Swap**: Automatic zram-generator setup (half of RAM, zstd, capped at 8GB) when no disk swap exists
- **Intelligent Storage Optimization**: Automatic I/O scheduler detection (NVMe: none, SSD: mq-deadline, HDD: bfq)
- **Advanced Kernel Tuning**: BBR congestion control, fq_codel queue discipline, filesystem-specific tuning
- **Hardware-Aware Configuration**: NVMe detection, virtualization awareness
- **Transparent Hugepages**: Disabled for desktop systems to improve performance
- **Persistent Settings**: All optimizations survive reboots via udev rules and systemd services
- **GPU Driver Detection**: Automatic installation of AMD/Intel drivers with Vulkan support; optional NVIDIA open-kernel-module setup with early KMS

#### Performance Optimization
- **I/O Scheduling**: Automatic selection based on storage type (NVMe: none, SSD: mq-deadline, HDD: bfq)
- **Memory Management**: Dynamic swappiness based on total RAM
- **Parallel Downloads**: Pacman parallel package fetching (10 concurrent)

### Desktop Environment Integration
| Environment | Optimizations | Features |
|-------------|---------------|----------|
| **KDE Plasma 6+** | DE-specific packages (bluedevil, dolphin, kate, okular, etc.) | KDE Connect integration, plasma-firewall, kwallet-pam (auto wallet unlock), power-profiles-daemon |
| **GNOME 46+** | DE-specific packages (adw-gtk-theme, gnome-tweaks, seahorse, etc.) | Extension manager, dark theme, modern tweaks |
| **Cosmic** | DE-specific packages (transmission-gtk) | Cosmic Tweaks via Flatpak |

Audio is handled by a complete PipeWire stack (pipewire, wireplumber, pipewire-alsa/jack/pulse). If PulseAudio is present it is replaced to avoid conflicts.

### Security & Stability

#### Security Hardening (Enabled by Default)
```bash
# Firewall Configuration
UFW/Firewalld:
  - Secure-by-default policies (deny incoming, allow outgoing)
  - SSH automatically allowed
  - KDE Connect ports opened when detected (1714-1764/tcp/udp)
  - EndeavourOS uses firewalld by default, Arch uses UFW
  - Firewalld default zone: block (safer than drop, denies without ICMP responses)
  - Idempotent: safe to re-run without duplicating rules

# SSH Protection
Fail2ban:
  - Auto-detects firewall backend and uses the correct banaction:
    * UFW        → banaction = ufw
    * Firewalld  → banaction = firewallcmd-ipset (modern; replaces deprecated firewallcmd-allports)
    * Neither    → banaction = iptables-multiport (fail2ban default)
  - Drops configuration in /etc/fail2ban/jail.d/archinstaller.local (survives package updates)
  - Configured BEFORE service start (jails active from first boot)
  - sshd jail explicitly enabled — no silent no-op protection
  - 1-hour ban duration (increased from default 10min)
  - 3 retry limit (decreased from default 5)
  - systemd backend for better integration
  - Daemon readiness verified with polling (not fixed sleep)
  - Legacy jail.local (no jails enabled) auto-detected and migrated
  - SSH jail validated as active before reporting success

# User Security
Sudo:
  - Password feedback enabled
  - User added to groups: wheel, video, storage, optical, scanner, lp, rfkill
  - Hardware access permissions configured
```

### System Services Configuration

The system services step includes comprehensive service management:

| Service Type | Services Enabled | Notes |
|--------------|------------------|-------|
| **Essential** | cronie, sshd, fstrim.timer, paccache.timer | All modes |
| **Desktop** | bluetooth.service | Standard/Minimal/Gaming (not Server) |
| **Power Profiles** | power-profiles-daemon.service | Plasma systems — enables Performance/Balanced/Power Saver switching |
| **Optional** | rustdesk.service, timeshift-autosnap.timer OR limine-snapper-sync.service | Snapshot tooling is bootloader-aware (see below) |
| **Firewall** | UFW or Firewalld | UFW for Arch, Firewalld for EndeavourOS |
| **GPU Drivers** | AMD/Intel with Vulkan; NVIDIA opt-in | Auto-detected and installed |
| **Audio** | PipeWire stack | Replaces PulseAudio if present |

### Snapshot Strategy (Bootloader-Aware)

The installer picks the right snapshot tooling for your bootloader automatically:

| Bootloader | Root FS | Snapshot Tool | Boot Menu Integration |
|------------|---------|---------------|----------------------|
| **Limine** | btrfs | Snapper + snap-pac + limine-snapper-sync | ✅ Bootable `Snapshots` submenu in Limine, auto-synced |
| **GRUB** | any | Timeshift + timeshift-autosnap | Rollback via Timeshift |
| **systemd-boot** | any | Timeshift + timeshift-autosnap | Rollback via Timeshift |

On Limine + btrfs systems, limine-snapper-sync keeps the Limine snapshot entries always in sync with snapper: newly created snapshots appear in the boot menu, deleted ones disappear. Snapshots taken before pacman transactions (via snap-pac) can be booted directly for rollback.

> **Note:** The AUR build of limine-snapper-sync occasionally fails due to upstream gradle issues. This is non-fatal — snapshots still work via snapper/snap-pac; only the automatic boot-menu sync needs a later retry with `yay -S limine-snapper-sync`.

### Gaming Mode (Optional)

Transform your system into a gaming powerhouse with one click:

| Component | Description |
|-----------|-------------|
| **Steam** | Native gaming platform with Proton support |
| **Heroic Games Launcher** | Epic Games + GOG support (Flatpak) |
| **Faugus Launcher** | Game management and launcher (Flatpak) |
| **ProtonPlus** | Proton-GE installer (Flatpak) |
| **Discord** | Voice and text chat for gamers |
| **MangoHud** | Vulkan/OpenGL overlay for monitoring FPS and performance |
| **Goverlay** | MangoHud configuration GUI |
| **GameMode** | Automatic performance tuning daemon |
| **Wine** | Windows compatibility layer |
| **lib32 packages** | 32-bit libraries for gaming (gamemode, mangohud) |
| **Multilib** | Automatically enabled for 32-bit gaming support | |

### Wake-on-LAN Configuration

Intelligent Wake-on-LAN setup for desktop systems with multi-adapter support:

| Feature | Detection | Configuration |
|---------|------------|-------------|
| **Laptop Detection** | Battery + DMI chassis | Auto-skip WoL on laptops |
| **Multi-Adapter Support** | All ethernet interfaces | Smart selection menu |
| **Internet Testing** | Ping + route checking | Prioritizes active connection |
| **Persistent Services** | systemd integration | Survives reboots automatically |
| **MAC Display** | Interface enumeration | Easy remote wake-up setup |

---

## Installation Modes

Choose the perfect setup for your use case:

| Mode | Use Case | Requirements |
|------|-------------|-------------|
| **Standard** | Full-featured desktop | General users, enthusiasts |
| **Minimal** | Lightweight essentials | Low-spec hardware, minimal bloat |
| **Server** | Headless configuration | Docker, SSH, server utilities |
| **Gaming** | Gaming-optimized | Steam, Heroic Games Launcher, Faugus Launcher, performance tools |

> **Note:** The installer auto-detects headless systems and switches to Server mode automatically. Use `--dry-run` to preview what would be installed without making any changes.

---

## Quick Start

### Prerequisites

- Fresh Arch Linux installation (minimal base system)
- Active internet connection
- User account with sudo privileges
- 2GB+ free disk space

### Installation

```bash
# Clone and run
git clone https://github.com/GAndromidas/archinstaller.git
cd archinstaller
./install.sh
```

**One-Click Setup:** The installer handles everything automatically - just select your preferred mode and let it configure your system.

### Command-Line Options

```bash
./install.sh [OPTIONS]

OPTIONS:
  -h, --help      Show help message
  -v, --verbose   Enable detailed output
  -q, --quiet     Minimal output mode
  -d, --dry-run   Preview changes only
  -f, --force     Re-apply all settings (re-runs steps even if previously completed)
```

#### Update Workflow

When you update the installer (e.g., `git pull`), use `--force` to re-apply new defaults to an already-configured system:

```bash
git pull              # get latest changes
./install.sh --force  # re-apply updated settings, skip completed steps
```

Without `--force`, the installer uses its built-in idempotency (state file at `~/.archinstaller.state`, config diff checks, `pacman --needed`) to skip already-applied steps safely. With `--force`, all main steps re-run to pick up the latest defaults.

#### Resume from Interruption

If the installer is interrupted (Ctrl+C, crash, reboot), just re-run it. It detects the state file and offers to resume, retry failed steps, or start fresh.

---

## Customization

### Package Management

All packages are organized in `configs/programs.yaml` with logical groupings:

```yaml
# Package Structure
pacman:          # Core packages (all modes)
essential:       # Mode-specific packages
desktop_environments:  # DE-specific packages
aur:             # AUR packages
flatpak:         # Flatpak applications
```

**Easy Customization:**

1. Open `configs/programs.yaml`
2. Add/remove packages from relevant sections
3. No script modification needed
4. Run installer - custom packages installed automatically

### Configuration Files

| File | Purpose |
|------|---------|
| `.zshrc` | Zsh shell configuration with Oh-My-Zsh |
| `starship.toml` | Starship prompt theme configuration |
| `config.jsonc` | Fastfetch system info configuration |
| `gaming_mode.yaml` | Gaming package definitions (Steam, Wine, GameMode, etc.) |
| `programs.yaml` | Package lists for all modes and desktop environments |
| `MangoHud.conf` | MangoHud gaming overlay configuration |

---

## What Gets Installed

### Common Across All Modes

- System utilities (android-tools, bat, btop, eza, fastfetch, fzf, starship, zoxide, expac, cmatrix, cpupower, dosfstools, duf, firefox, fwupd, gnome-disk-utility, hwinfo, inxi, ncdu, net-tools, nmap, noto-fonts-extra, samba, sl, speedtest-cli, sshfs, ttf-hack-nerd, ttf-liberation, unrar, wakeonlan, xdg-desktop-portal-gtk)
- Development essentials (base-devel, git, curl)
- Zsh shell with Oh-My-Zsh, Starship prompt, Fastfetch
- System monitoring tools (btop, inxi, hwinfo)
- Pacman optimization (ParallelDownloads, Color, VerbosePkgLists, ILoveCandy, multilib)
- CPU microcode (intel-ucode or amd-ucode)
- Kernel headers for all installed kernels
- Locale generation (en_US.UTF-8 + auto-detected country locale)

### Mode-Specific Packages
| Mode | Desktop | Applications | Tools |
|------|-------------|-------------|------|
| **Standard** | Full DE (KDE/GNOME/Cosmic) | Filezilla, Kdenlive, LibreOffice, Dropbox, RustDesk, Ventoy | Performance monitoring |
| **Minimal** | Lightweight DE | MPV, RustDesk | Basic utilities |
| **Server** | No DE | Docker, Docker Compose, Nano | Server utilities (btop, inxi, nmap, samba) |
| **Gaming** | Gaming-optimized DE | Steam, Heroic Games Launcher, Faugus Launcher, Wine, Discord | GameMode, MangoHud, Goverlay |

### Installation Steps

The installer includes 10 comprehensive steps for complete system setup:

| Step | Description | Mode Coverage |
|------|-------------|---------------|
| **1. System Preparation** | Pacman configuration, helper utilities, system update, CPU microcode, kernel headers, locales | All modes |
| **2. Shell Setup** | Zsh + Oh-My-Zsh + Starship + Fastfetch | All modes |
| **3. Yay Installation** | AUR helper setup | All modes |
| **4. Programs Installation** | Mode-specific applications from YAML configs | All modes |
| **5. Gaming Mode** | Steam, Wine, GameMode, MangoHud, Discord, gaming launchers | Gaming mode only |
| **6. Bootloader Configuration** | Kernel params, GRUB/systemd-boot/Limine config, snapshot integration (Limine+btrfs) | Standard/Minimal/Gaming |
| **7. Fail2ban Setup** | SSH security hardening (configured before service start) | All modes |
| **8. System Services** | Firewall (UFW/Firewalld), user groups, GPU drivers, PipeWire audio, zRAM, power management | All modes |
| **9. Wake-on-LAN Configuration** | Multi-adapter WoL setup with laptop detection | Desktop systems |
| **10. Maintenance** | Cache cleanup (keeps 2 versions for rollback), orphan removal, SSD optimization | All modes |

---

## Security Features

### Enabled by Default
```bash

| Feature | Status | Configuration |
|---------|--------|---------------|
| **Firewall** | Active | UFW (Arch) or Firewalld (EndeavourOS) with secure policies |
| **SSH Protection** | Active | Fail2ban with 1hr ban, 3 retries, systemd backend, sshd jail enabled; auto-detects firewall (ufw / firewallcmd-ipset / iptables-multiport) |
| **Wake-on-LAN** | Desktop Only | Multi-adapter with smart selection, laptop detection |
| **User Groups** | Active | wheel, video, storage, optical, scanner, lp, rfkill |
| **Bootloader** | Active | GRUB/systemd-boot/Limine with kernel optimization |
| **Sudo** | Active | Password feedback enabled (validated via visudo before install) |
| **Snapshots** | Bootloader-aware | Snapper+Limine menu (btrfs) or Timeshift+autosnap |

---

## Supported Platforms

### Hardware Support

| Component | Support | Notes |
|-----------|---------|-------|
| **CPU** | Intel, AMD | Microcode + optimizations |
| **GPU** | AMD, Intel, NVIDIA* | Driver auto-detection; NVIDIA proprietary is opt-in |
| **Storage** | NVMe, SSD, HDD | I/O scheduler optimization |
| **Form Factor** | Desktop, Laptop, VM | Power management + thermal |
| **Laptop Brands** | 15+ Manufacturers | Brand-specific optimizations |

\* NVIDIA: installs nvidia-open (or nvidia-open-lts) with DRM kernel mode setting for Wayland. Recommended for Turing (GTX 16xx)+ GPUs; pre-Turing GPUs should stay on nouveau.

### Bootloader Support

- **GRUB** 2.x with timeout optimization
- **systemd-boot** with LTS kernel fallback
- **Limine** (modern UEFI bootloader)

### Desktop Environments

- **KDE Plasma** 6.x (Qt6-based) - bleeding edge only
- **GNOME** 46+ (latest stable)
- **Cosmic** (experimental, latest builds)

---

### Laptop Optimizations

The installer includes automatic laptop detection and optimizations:

#### Detection Methods
- Battery presence check (/sys/class/power_supply/BAT*)
- DMI chassis type detection (laptop, notebook, portable, etc.)
- Product name analysis for common laptop indicators

#### Optimizations Applied
- Battery vs AC power optimization
- CPU frequency scaling
- Thermal management
- Suspend/resume functionality

#### Supported Features
- Manufacturer-specific WMI module loading
- Function key and hotkey support
- Brightness, volume, WiFi toggle support
- ACPI event handling

---

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| **Installation Interrupted** | Resume from `~/.archinstaller.state` |
| **No Internet Connection** | Check `ping archlinux.org` |
| **Insufficient Disk Space** | Minimum 2GB free required |
| **Package Installation Failures** | Check `~/.archinstaller.log` |

### Log Files

```bash
~/.archinstaller.log     # Complete installation log
~/.archinstaller.state   # Progress tracking
```

### Bootloader Safety

Bootloader configuration changes are backed up automatically (`limine.conf.backup.<timestamp>` etc.) and only applied after validation. If a generated config would leave the system unbootable, the existing config is kept. Keep a live USB handy when testing bootloader changes.

---

## Contributing

### How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

### Contribution Types

- **Report bugs**: Open an issue with details
- **Suggest features**: Describe your use case
- **Improve code**: Submit a pull request
- **Update documentation**: Help others understand the project

---

## Project Status

| Component | Status |
|-----------|--------|
| **Core Functionality** | Production Ready |
| **Hardware Detection** | Stable |
| **Smart AMD P-State** | ✅ Implemented |
| **Advanced Optimizations** | ✅ CachyOS-Inspired |
| **Gaming Mode** | Tested |
| **Security Hardening** | Active |
| **Limine Snapshot Menu** | ✅ New — needs real-hardware testing |
| **NVIDIA (opt-in)** | ✅ New — needs real-hardware testing |
| **Documentation** | Complete |

### Recent Major Improvements

#### Production Hardening & Idempotency
- **🔁 Re-Apply After Updates**: New `--force` / `-f` flag re-runs all steps (state file bypassed, configs re-overwritten) so updating the installer and re-running actually applies new defaults
- **🆔 Full Idempotency by Default**: Plain re-runs safely skip already-applied settings via `pacman --needed`, config diffs, drop-in existence checks, and `pacman -Q` pre-checks — no duplicates, no broken configs
- **🔄 Resume from Interruption**: Detects `~/.archinstaller.state` on re-run; offers to resume, retry failed steps, or start fresh
- **🛡️ Production-Grade Error Handling**: All scripts use `set -euo pipefail` with `HOME` guard for chroot/fresh-install safety
- **⏱️ Reliable Polling**: `fail2ban` daemon readiness verified by polling, not fixed sleeps

#### Fail2ban Auto-Detection
- Detects firewall backend and uses the correct `banaction`:
  - UFW → `ufw` (integrates with UFW rules)
  - Firewalld → `firewallcmd-ipset` (modern; replaces deprecated `firewallcmd-allports`)
  - Neither → `iptables-multiport` (fail2ban default)
- `banaction` is read from `$FIREWALL_PREFERENCE` (set by distribution detection)
- Drops config in `/etc/fail2ban/jail.d/archinstaller.local` (survives package updates)
- Legacy `jail.local` (no jails enabled) is auto-detected and migrated

#### Robustness & Consistency Overhaul
- **🛡️ Safe Bootloader Configs**: Limine entries generated from all installed kernels with validation-before-install and automatic backup restore — no more unbootable configs
- **📸 Bootable Snapshots**: Limine + btrfs systems get a bootable snapshot menu via Snapper + limine-snapper-sync, always in sync; other bootloaders keep Timeshift + timeshift-autosnap
- **🪟 Correct Windows Dual-Boot**: Windows detected across drives via its ESP and added as a proper UEFI entry
- **🎮 Optional NVIDIA Support**: Opt-in nvidia-open installation with DRM mode setting for Wayland (Turing+)
- **🔊 Reliable Audio**: PipeWire stack installed unconditionally; PulseAudio replaced if present
- **💾 zRAM by Default**: zram-generator sized from RAM when no disk swap exists
- **⚡ Power Profiles**: power-profiles-daemon enabled on Plasma systems so powerdevil switching works
- **🔑 KWallet PAM**: Wallet unlocks automatically at login on KDE systems
- **🧪 Dry-Run That's Honest**: `--dry-run` now skips all mutating steps, not just package installs
- **🎨 Unified UI**: All yes/no prompts go through one helper with safe EOF/non-interactive defaults (never auto-confirms destructive actions)
- **🔧 Partial-Upgrade Safety**: Full `-Syu` upgrades everywhere; no blind `--overwrite` flags
- **🧹 Safer Maintenance**: Age-based /tmp cleanup (live session sockets preserved), pacman cache keeps 2 versions for rollback

---

## License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

You are free to use, modify, and distribute this software for personal or commercial purposes.

---

## Acknowledgments

- Inspired by Arch Linux philosophy: simplicity and user control
- Built with community best practices and feedback
- Thanks to all contributors and users

---

## Support & Contact

| Platform | Link |
|----------|------|
| **Issues** | [GitHub Issues](https://github.com/GAndromidas/archinstaller/issues) |
| **Discussions** | [GitHub Discussions](https://github.com/GAndromidas/archinstaller/discussions) |
| **Repository** | [github.com/GAndromidas/archinstaller](https://github.com/GAndromidas/archinstaller) |

---

<div align="center">

## Made with love for the Arch Linux community

If you find this useful, please consider starring the repository!

[![Star](https://img.shields.io/github/stars/GAndromidas/archinstaller.svg?style=social&logo=github)](https://github.com/GAndromidas/archinstaller/stargazers)

</div>