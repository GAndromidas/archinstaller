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
  NVIDIA: Proprietary drivers + CUDA support
  AMD: Open-source drivers + Vulkan
  Intel: Integrated graphics + VA-API
  
Storage Optimization:
  NVMe: BFQ scheduler + trim optimizations
  SSD: Deadline scheduler + wear leveling
  HDD: CFQ scheduler + readahead settings
  
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

#### Advanced Performance Optimization (CachyOS-Inspired)

- **Smart Memory Management**: Dynamic swappiness based on system RAM (2GB: 10, 4GB: 10, 8GB: 5, 16GB+: 1)
- **Intelligent Storage Optimization**: Automatic I/O scheduler detection (NVMe: none, SSD: deadline, HDD: mq-deadline)
- **Advanced Kernel Tuning**: Process scheduling, network stack optimization, filesystem-specific tuning
- **Hardware-Aware Configuration**: NVMe detection, zRAM monitoring, virtualization awareness
- **Transparent Hugepages**: Disabled for desktop systems to improve performance
- **Persistent Settings**: All optimizations survive reboots via udev rules and systemd services
- **GPU Driver Detection**: Automatic installation of AMD/Intel/NVIDIA drivers with Vulkan support

#### Performance Optimization
- **I/O Scheduling**: Automatic selection based on storage type
- **Kernel Tuning**: `vm.swappiness=10`, `fs.inotify.max_user_watches=524288`
- **Parallel Downloads**: Pacman parallel package fetching (10 concurrent)
- **Memory Management**: ZRAM compression + swap optimization

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
  - systemd backend for better integration
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
| **Desktop** | bluetooth.service | Standard/Minimal/Gaming (not Server) |
| **Optional** | rustdesk.service, timeshift-autosnap.timer | If installed |
| **Firewall** | UFW or Firewalld | UFW for Arch, Firewalld for EndeavourOS |
| **Power Management** | power-profiles-daemon or tuned-ppd | Automatic power mode switching |
| **GPU Drivers** | AMD/Intel/NVIDIA with Vulkan | Auto-detected and installed |

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

The installer includes 11 comprehensive steps for complete system setup:

| Step | Description | Mode Coverage |
|------|-------------|---------------|
| **1. System Preparation** | Pacman configuration, helper utilities, system update, CPU microcode, kernel headers, locales | All modes |
| **2. Shell Setup** | Zsh + Oh-My-Zsh + Starship + Fastfetch | All modes |
| **3. Plymouth Setup** | Boot screen configuration (bgrt/spinner themes) | Standard/Minimal/Gaming |
| **4. Yay Installation** | AUR helper setup | All modes |
| **5. Programs Installation** | Mode-specific applications from YAML configs | All modes |
| **6. Gaming Mode** | Steam, Wine, GameMode, MangoHud, Discord, gaming launchers | Gaming mode only |
| **7. Bootloader Configuration** | GRUB/systemd-boot/Limine with kernel optimization | All modes |
| **8. Fail2ban Setup** | SSH security hardening (1hr ban, 3 retries) | All modes |
| **9. System Services** | Firewall (UFW/Firewalld), user groups, GPU drivers, power management | All modes |
| **10. Wake-on-LAN Configuration** | Multi-adapter WoL setup with laptop detection | Desktop systems |
| **11. Maintenance** | Cache cleanup, orphan removal, SSD optimization | All modes |

---

## Security Features

### Enabled by Default
```bash

| Feature | Status | Configuration |
|---------|--------|---------------|
| **Firewall** | Active | UFW (Arch) or Firewalld (EndeavourOS) with secure policies |
| **SSH Protection** | Active | Fail2ban with 1hr ban, 3 retries, systemd backend |
| **Wake-on-LAN** | Desktop Only | Multi-adapter with smart selection, laptop detection |
| **User Groups** | Active | wheel, video, storage, optical, scanner, lp, rfkill |
| **Bootloader** | Active | GRUB/systemd-boot/Limine with kernel optimization |
| **Sudo** | Active | Password feedback enabled |

---

## Supported Platforms

### Hardware Support

| Component | Support | Notes |
|-----------|---------|-------|
| **CPU** | Intel, AMD | Microcode + optimizations |
| **GPU** | NVIDIA, AMD, Intel | Driver auto-detection |
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
- Power profile management (power-profiles-daemon or tuned-ppd)
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
| **Documentation** | Complete |

### Recent Major Improvements

#### Comprehensive System Configuration
- **🚀 Complete Package Management**: YAML-based configuration for all modes and desktop environments
- **🎮 Gaming Mode**: Steam, Wine, GameMode, MangoHud, Discord with Flatpak integration
- **🛡️ Enhanced Security**: Fail2ban with 1hr ban, 3 retries, systemd backend
- **� Service Management**: Automatic firewall (UFW/Firewalld), user groups, GPU drivers
- **� Laptop Detection**: Automatic laptop detection with power management optimizations
- **🌐 Wake-on-LAN**: Multi-adapter support with smart selection and laptop detection
- **🎨 Desktop Integration**: DE-specific packages for KDE Plasma 6+, GNOME 46+, Cosmic

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