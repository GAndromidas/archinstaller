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

---

## Key Features

### System Intelligence & Automation

#### Hardware Detection
```yaml
CPU Detection:
  Intel: intel-ucode + microcode updates
  AMD: amd-ucode + microcode updates
  
GPU Detection:
  AMD: Open-source drivers + Vulkan
  Intel: Integrated graphics + VA-API
  NVIDIA: GPU detection with driver configuration
  
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
| **Limine** | Modern UEFI, fast boot support | Simple configuration |

#### Advanced Performance Optimization

- **Smart Memory Management**: Dynamic swappiness based on system RAM (<4GB: 60, 4-8GB: 30, 8-16GB: 10, 16GB+: 1)
- **Intelligent Storage Optimization**: Automatic I/O scheduler detection (NVMe: none, SSD: mq-deadline, HDD: bfq)
- **Advanced Kernel Tuning**: Process scheduling, network stack optimization, filesystem-specific tuning
- **Hardware-Aware Configuration**: NVMe detection, zRAM monitoring, virtualization awareness
- **Transparent Hugepages**: Disabled for desktop systems to improve performance
- **Persistent Settings**: All optimizations survive reboots via udev rules and systemd services
- **GPU Driver Detection**: Automatic installation of AMD/Intel drivers with Vulkan support

#### Performance Optimization
- **I/O Scheduling**: Automatic selection based on storage type (NVMe: none, SSD: mq-deadline, HDD: bfq)
- **Memory Management**: Dynamic swappiness based on total RAM
- **Parallel Downloads**: Dynamic ParallelDownloads based on available RAM (4-16 concurrent)
- **Package Management**: Single pacman sync, batch Flatpak installs, yay BatchInstall

### Desktop Environment Integration
| Environment | Optimizations | Features |
|-------------|---------------|----------|
| **KDE Plasma 6+** | DE-specific packages (bluedevil, dolphin, kate, okular, etc.) | KDE Connect integration, plasma-firewall, system monitor |
| **GNOME 46+** | DE-specific packages (adw-gtk-theme, gnome-tweaks, seahorse, etc.) | Extension manager, dark theme, modern tweaks |
| **Cosmic** | DE-specific packages (transmission-gtk) | Cosmic Tweaks via Flatpak |

### Security & Stability

#### Security Hardening (Enabled by Default)
```bash
# Firewall Configuration
UFW/Firewalld:
  - Secure-by-default policies (deny incoming, allow outgoing)
  - SSH automatically allowed
  - KDE Connect ports opened when detected (1714-1764/tcp/udp)
  - EndeavourOS uses firewalld by default, Arch uses UFW

# SSH Protection
Fail2ban:
  - 1-hour ban duration (increased from default 10min)
  - 3 retry limit (decreased from default 5)
  - Auto-detects ufw or firewalld backend for proper integration
  - Automatic brute-force detection

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
| **Desktop** | bluetooth.service | Standard/Minimal (not Server) |
| **Optional** | rustdesk.service, timeshift-autosnap.timer | If installed |
| **Firewall** | UFW or Firewalld | Auto-detected; fail2ban configures backend accordingly |
| **Server** | systemd-timesyncd | Server mode only |
| **GPU Drivers** | AMD/Intel with Vulkan | Auto-detected and installed |

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
| **Server** | Headless configuration | Docker, Docker Compose, sysctl tuning, no Portainer/Watchtower |

**Gaming Mode** is offered as an optional add-on during Standard or Minimal installation.

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
  --server        Configure as server (Docker, sysctl tuning, no Portainer/Watchtower)
```

### Server Mode Configuration

When running with `--server`, the installer configures:

```yaml
Docker Hardening:
  - Log rotation: 10MB max, 3 files
  - Live-restore: enabled
  - No-new-privileges: enabled
  - Userland proxy: disabled
  - Iptables: enabled

Sysctl Tuning:
  - TCP keepalive: 60s interval, 6 probes
  - File descriptors: 65536 max
  - TCP reuse: enabled
  - TCP fin timeout: 15s
  - Buffer sizes: optimized for throughput

Time Synchronization:
  - systemd-timesyncd enabled

Packages:
  - Docker + Docker Compose (no Portainer/Watchtower)
  - htop, tmux, rsync, base-devel
```

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

- System utilities (android-tools, bat, btop, chromium, cmatrix, cpupower, dosfstools, duf, firefox, fwupd, gnome-disk-utility, hwinfo, inxi, ncdu, net-tools, nmap, noto-fonts-extra, samba, sl, speedtest-cli, sshfs, ttf-hack-nerd, ttf-liberation, unrar, wakeonlan, xdg-desktop-portal-gtk)
- Development essentials (base-devel, git, curl)
- Zsh shell with Oh-My-Zsh, Starship prompt, Fastfetch
- System monitoring tools (btop, inxi, hwinfo)
- Pacman optimization (Dynamic ParallelDownloads based on RAM, Color, VerbosePkgLists, ILoveCandy, multilib)
- CPU microcode (intel-ucode or amd-ucode)
- Kernel headers for all installed kernels
- Locale generation (en_US.UTF-8 + auto-detected country locale)
### Mode-Specific Packages

| Mode | Desktop | Applications | Tools |
|------|-------------|-------------|------|
| **Standard** | Full DE (KDE/GNOME/Cosmic) | Filezilla, Kdenlive, LibreOffice, Dropbox, RustDesk, Ventoy | Performance monitoring |
| **Minimal** | Lightweight DE | MPV, RustDesk | Basic utilities |
| **Server** | No DE | Docker + Docker Compose only | Server utilities (btop, inxi, nmap, samba, htop, tmux, rsync, base-devel) |

### Installation Steps

The installer includes 10 comprehensive steps for complete system setup:

| Step | Description | Mode Coverage |
|------|-------------|---------------|
| **1. System Preparation** | Pacman configuration, helper utilities, system update, CPU microcode, kernel headers, locales | All modes |
| **2. Shell Setup** | Zsh + Oh-My-Zsh + Starship + Fastfetch | All modes |
| **3. Yay Installation** | AUR helper setup | All modes |
| **4. Programs Installation** | Mode-specific applications from YAML configs | All modes |
| **5. Gaming Mode** | Steam, Wine, GameMode, MangoHud, Discord, gaming launchers | Optional (Standard/Minimal) |
| **6. Bootloader Configuration** | Kernel params, GRUB/systemd-boot/Limine config | Standard/Minimal/Gaming |
| **7. System Services** | Firewall (UFW/Firewalld), user groups, GPU drivers, power management | All modes |
| **8. Fail2ban Setup** | SSH security hardening (1hr ban, 3 retries, auto-detects firewall backend) | All modes |
| **9. Wake-on-LAN Configuration** | Multi-adapter WoL setup with laptop detection | Desktop systems only (skipped in server mode) |
| **10. Maintenance** | Cache cleanup (paccache), orphan removal, SSD optimization | All modes |

---

## Security Features

### Enabled by Default

| Feature | Status | Configuration |
|---------|--------|---------------|
| **Firewall** | Active | UFW (Arch) or Firewalld (EndeavourOS) with secure policies |
| **SSH Protection** | Active | Fail2ban with 1hr ban, 3 retries, auto-detects ufw/firewalld backend |
| **Wake-on-LAN** | Desktop Only | Skipped in server mode; multi-adapter with smart selection, laptop detection |
| **User Groups** | Active | wheel, video, storage, optical, scanner, lp, rfkill |
| **Bootloader** | Active | GRUB/systemd-boot/Limine with kernel optimization |
| **Sudo** | Active | Password feedback enabled |

---

## Supported Platforms

### Hardware Support

| Component | Support | Notes |
|-----------|---------|-------|
| **CPU** | Intel, AMD | Microcode + optimizations |
| **GPU** | AMD, Intel, NVIDIA | Driver auto-detection |
| **Storage** | NVMe, SSD, HDD | I/O scheduler optimization |
| **Form Factor** | Desktop, Laptop, VM | Power management + thermal |
| **Laptop Brands** | 15+ Manufacturers | Brand-specific optimizations |

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
| **Installation Interrupted** | Resume from `/tmp/archinstaller.state` |
| **No Internet Connection** | Check `ping archlinux.org` |
| **Insufficient Disk Space** | Minimum 2GB free required |
| **Package Installation Failures** | Check `/tmp/archinstaller.log` |

### Log Files

```bash
/tmp/archinstaller.log     # Complete installation log
/tmp/archinstaller.state   # Progress tracking
```

> **Note:** Log files are stored in `/tmp` and are automatically cleaned up on reboot. Manual cleanup is available via the post-install prompt.

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
| **Smart AMD P-State** | Implemented |
| **Advanced Optimizations** | Implemented |
| **Dashboard UI** | Professional Wizard-Style |
| **Gaming Mode** | Tested |
| **Server Mode** | Production Ready |
| **Security Hardening** | Active |
| **Comprehensive Logging** | All output captured |
| **Documentation** | Complete |

### Recent Major Improvements

#### Performance & Reliability
- **Speed Optimizations**: Single pacman sync, dynamic ParallelDownloads based on RAM, batch Flatpak installs, yay BatchInstall, Flathub added once
- **Dashboard UI**: Professional wizard-style display with step timers, progress bars, and elapsed time
- **Resume Support**: Automatic detection of interrupted installations with state tracking
- **Smart Caching**: Cached `supports_gum()` check, removed unnecessary sleeps

#### Server Mode Enhancements
- **CLI Flag**: `--server` flag for headless configuration
- **Docker Hardening**: daemon.json with log rotation, live-restore, no-new-privileges, disable userland-proxy
- **Sysctl Tuning**: TCP keepalive, file descriptors, buffer sizes, connection reuse for servers
- **Time Synchronization**: systemd-timesyncd enabled for server time sync
- **Package Cleanup**: Removed Portainer/Watchtower; only Docker + Docker Compose

#### Security & Bug Fixes
- **Fail2ban**: Auto-detects ufw or firewalld backend for proper integration
- **15 Bug Fixes**: Server mode exit 0, mirrorlist URL, background mirror race, NVIDIA GPU detection, printf ANSI escapes, and more
- **Timer Fixes**: Negative elapsed time clamped, accurate wall time tracking
- **Comprehensive Logging**: All `ui_*` functions now log to file; log and state files moved to `/tmp` for auto-cleanup

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