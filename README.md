<div align="center">

# <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/logo.png" alt="Archinstaller Logo" width="120"/>

# Archinstaller

[![GitHub release](https://img.shields.io/github/release/GAndromidas/archinstaller.svg?style=for-the-badge&logo=github)](https://github.com/GAndromidas/archinstaller/releases)
[![Last Commit](https://img.shields.io/github/last-commit/GAndromidas/archinstaller.svg?style=for-the-badge&logo=git)](https://github.com/GAndromidas/archinstaller/commits/main)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge&logo=open-source-initiative)](LICENSE)
[![Arch Linux](https://img.shields.io/badge/Platform-Arch%20Linux-1793E1?style=for-the-badge&logo=arch-linux)](https://archlinux.org/)
[![Stars](https://img.shields.io/github/stars/GAndromidas/archinstaller.svg?style=for-the-badge&logo=star)](https://github.com/GAndromidas/archinstaller/stargazers)

**Professional Arch Linux Post-Installation Automation**

Transform your minimal Arch Linux installation into a fully configured, optimized system with intelligent hardware detection and tailored optimizations.

[Quick Start](#-quick-start) · [Features](#-key-features) · [Installation Modes](#-installation-modes) · [Configuration](#-customization)

</div>

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/overview.png" alt="Overview" width="30"/> Overview

**Archinstaller** is a sophisticated post-installation automation tool that intelligently configures Arch Linux based on your hardware. It applies targeted optimizations rather than one-size-fits-all settings, ensuring optimal performance for your specific configuration.

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/philosophy.png" alt="Philosophy" width="25"/> Core Philosophy

| Philosophy | Description |
|------------|-------------|
| **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/hardware.png" alt="Hardware" width="20"/> Hardware-Aware** | Detects CPU, GPU, storage, and desktop environment for tailored optimizations |
| **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/security.png" alt="Security" width="20"/> Security-First** | Comprehensive hardening enabled by default with firewall and fail2ban |
| **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/performance.png" alt="Performance" width="20"/> Performance-Optimized** | Intelligent I/O scheduling and kernel tuning for optimal responsiveness |
| **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/reliable.png" alt="Reliable" width="20"/> Reliable** | Resume functionality for interrupted installations with progress tracking |

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/features.png" alt="Features" width="30"/> Key Features

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/intelligence.png" alt="Intelligence" width="25"/> System Intelligence & Automation

#### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/hardware-detection.png" alt="Hardware Detection" width="20"/> Hardware Detection
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
  Power management + thermal throttling
  Battery optimization + suspend/resume
```

#### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/bootloader.png" alt="Bootloader" width="20"/> Bootloader Detection & Configuration
| Bootloader | Features | Integration |
|------------|----------|-------------|
| **GRUB** | Snapshot entries, timeout optimization | grub-btrfs + grub-btrfsd |
| **systemd-boot** | LTS kernel fallback, EFI support | Automatic entry management |
| **Limine** | Modern UEFI, fast boot | limine-snapper-sync |

#### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/performance.png" alt="Performance" width="20"/> Performance Optimization
- **I/O Scheduling**: Automatic selection based on storage type
- **Kernel Tuning**: `vm.swappiness=10`, `fs.inotify.max_user_watches=524288`
- **Parallel Downloads**: Pacman parallel package fetching
- **Memory Management**: ZRAM compression + swap optimization

#### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/desktop.png" alt="Desktop" width="20"/> Desktop Environment Integration
| Environment | Optimizations | Features |
|-------------|---------------|----------|
| **KDE Plasma** | Custom shortcuts, workspace optimization | kglobalshortcutsrc + performance tweaks |
| **GNOME** | Dark theme, window manager tweaks | dconf settings + gesture support |
| **Cosmic** | Full environment support | Experimental DE integration |

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/security.png" alt="Security" width="25"/> Security & Stability

#### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/firewall.png" alt="Firewall" width="20"/> Security Hardening (Enabled by Default)
```bash
# Firewall Configuration
UFW/Firewalld:
  - Secure-by-default policies
  - Deny incoming, allow outgoing
  - SSH automatically allowed
  - Service-aware port management

# SSH Protection
Fail2ban:
  - Strict SSH policies
  - 15-minute ban on suspicious activity
  - Automatic brute-force detection
  - Customizable ban thresholds

# User Security
Sudo:
  - Password feedback enabled
  - Proper user group membership
  - Hardware access permissions
```

#### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/snapshot.png" alt="Snapshot" width="20"/> Btrfs Snapshot System
- **Full Solution**: Snapper + bootloader integration
- **Automatic Snapshots**: Before/after package operations
- **GUI Management**: btrfs-assistant for easy rollback
- **Boot Integration**: GRUB/systemd-boot/Limine snapshot entries

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/gaming.png" alt="Gaming" width="25"/> Gaming Mode (Optional)

Transform your system into a gaming powerhouse with one click:

| Component | Description |
|-----------|-------------|
| **Steam** | Native gaming platform with Proton |
| **Lutris** | Multiple gaming platform support |
| **Heroic Games Launcher** | Epic Games + GOG support |
| **MangoHud** | Performance overlay and monitoring |
| **Goverlay** | MangoHud configuration GUI |
| **GameMode** | Automatic performance tuning |

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/peripherals.png" alt="Peripherals" width="25"/> Smart Peripheral Detection

Automatically detects connected peripherals and installs appropriate management software:

| Peripheral | Detection | Software |
|------------|------------|----------|
| **Logitech Devices** | USB vendor ID | Solaar (Unifying Receiver) |
| **Keychron Keyboards** | Device name | VIA-bin (keyboard configuration) |
| **Gaming Mice** | HID detection | libratbag + Piper |
| **Razer Devices** | Vendor ID | OpenRazer + Polychromatic |
| **Generic HID** | USB/HID tree | hidapi + udev rules |

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/modes.png" alt="Modes" width="30"/> Installation Modes

Choose the perfect setup for your use case:

<div align="center">

| Mode | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/desktop.png" alt="Desktop" width="20"/> Use Case | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/specs.png" alt="Specs" width="20"/> Requirements |
|------|-------------|-------------|
| **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/standard.png" alt="Standard" width="25"/> Standard** | Full-featured desktop | General users, enthusiasts |
| **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/minimal.png" alt="Minimal" width="25"/> Minimal** | Lightweight essentials | Low-spec hardware, minimal bloat |
| **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/server.png" alt="Server" width="25"/> Server** | Headless configuration | Docker, SSH, server utilities |
| **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/custom.png" alt="Custom" width="25"/> Custom** | Interactive selection | Power users, specific requirements |
| **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/gaming.png" alt="Gaming" width="25"/> Gaming** | Gaming-optimized | Steam, Lutris, performance tools |

</div>

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/rocket.png" alt="Quick Start" width="30"/> Quick Start

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/prerequisites.png" alt="Prerequisites" width="25"/> Prerequisites

- **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/arch.png" alt="Arch" width="20"/> Fresh Arch Linux installation** (minimal base system)
- **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/internet.png" alt="Internet" width="20"/> Active internet connection**
- **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/user.png" alt="User" width="20"/> User account with sudo privileges**
- **<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/storage.png" alt="Storage" width="20"/> 2GB+ free disk space**

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/installation.png" alt="Installation" width="25"/> Installation

<div align="center">

```bash
# Clone and run
git clone https://github.com/GAndromidas/archinstaller.git
cd archinstaller
./install.sh
```

**<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/magic.png" alt="Magic" width="20"/> One-Click Setup:** The installer handles everything automatically - just select your preferred mode and let it configure your system.

</div>

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/cli.png" alt="CLI" width="25"/> Command-Line Options

```bash
./install.sh [OPTIONS]

OPTIONS:
  -h, --help      Show help message
  -v, --verbose   Enable detailed output
  -q, --quiet     Minimal output mode
  -d, --dry-run   Preview changes only
```

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/interface.png" alt="Interface" width="25"/> Installation Experience

<div align="center">

```
<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/installer-interface.png" alt="Installer Interface"/>
```

</div>

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/config.png" alt="Configuration" width="30"/> Customization

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/packages.png" alt="Packages" width="25"/> Package Management

All packages are organized in `configs/programs.yaml` with logical groupings:

```yaml
# Package Structure
pacman:          # Core packages (all modes)
essential:       # Mode-specific packages
desktop_environments:  # DE-specific packages
aur:             # AUR packages
flatpak:         # Flatpak applications
custom:          # Optional additions
```

**<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/easy.png" alt="Easy" width="20"/> Easy Customization:**

1. Open `configs/programs.yaml`
2. Add/remove packages from relevant sections
3. No script modification needed
4. Run installer - custom packages installed automatically

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/files.png" alt="Files" width="25"/> Configuration Files

| File | Purpose |
|------|---------|
| `.zshrc` | Zsh shell configuration |
| `starship.toml` | Starship prompt theme |
| `kglobalshortcutsrc` | KDE keyboard shortcuts |
| `config.jsonc` | Fastfetch system info |
| `gaming_mode.yaml` | Gaming package definitions |

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/installed.png" alt="Installed" width="30"/> What Gets Installed

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/common.png" alt="Common" width="25"/> Common Across All Modes

- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/tools.png" alt="Tools" width="20"/> System utilities and tools
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/dev.png" alt="Dev" width="20"/> Development essentials
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/shell.png" alt="Shell" width="20"/> Zsh shell with Oh-My-Zsh
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/prompt.png" alt="Prompt" width="20"/> Starship terminal prompt
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/monitor.png" alt="Monitor" width="20"/> System monitoring tools

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/modes-detail.png" alt="Modes Detail" width="25"/> Mode-Specific Packages

| Mode | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/desktop.png" alt="Desktop" width="20"/> Desktop | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/apps.png" alt="Apps" width="20"/> Applications | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/tools.png" alt="Tools" width="20"/> Tools |
|------|-------------|-------------|------|
| **Standard** | Full DE (KDE/GNOME/Cosmic) | Multimedia, Office, IDEs | Performance monitoring |
| **Minimal** | Lightweight DE | Essential apps only | Basic utilities |
| **Server** | No DE | Docker, Portainer | Server utilities |
| **Gaming** | Gaming-optimized DE | Steam, Lutris, Heroic | Performance tools |

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/security-badge.png" alt="Security" width="30"/> Security Features

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/lock.png" alt="Lock" width="25"/> Enabled by Default

<div align="center">

| Feature | Status | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/status-icon.png" alt="Status Icon" width="20"/> |
|---------|--------|---------|
| **Firewall** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> Active | UFW/Firewalld with secure policies |
| **SSH Protection** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> Active | Fail2ban with strict policies |
| **User Groups** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> Active | Proper permissions configured |
| **Bootloader** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> Active | Security-hardened configuration |

</div>

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/support.png" alt="Support" width="30"/> Supported Platforms

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/hardware.png" alt="Hardware" width="25"/> Hardware Support

| Component | Support | Notes |
|-----------|---------|-------|
| **CPU** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> Intel, AMD | Microcode + optimizations |
| **GPU** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> NVIDIA, AMD, Intel | Driver auto-detection |
| **Storage** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> NVMe, SSD, HDD | I/O scheduler optimization |
| **Form Factor** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> Desktop, Laptop, VM | Power management + thermal |

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/bootloaders.png" alt="Bootloaders" width="25"/> Bootloader Support

- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> **GRUB** 2.x with Btrfs snapshot support
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> **systemd-boot** with LTS kernel fallback
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> **Limine** (modern UEFI bootloader)

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/desktops.png" alt="Desktops" width="25"/> Desktop Environments

- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> **KDE Plasma** 5.x and 6.x
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> **GNOME** 40+
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/check.png" alt="Check" width="20"/> **Cosmic** (experimental)

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/troubleshooting.png" alt="Troubleshooting" width="30"/> Troubleshooting

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/common-issues.png" alt="Common Issues" width="25"/> Common Issues

| Issue | Solution |
|-------|----------|
| **Installation Interrupted** | Resume from `~/.archinstaller.state` |
| **No Internet Connection** | Check `ping archlinux.org` |
| **Insufficient Disk Space** | Minimum 2GB free required |
| **Package Installation Failures** | Check `~/.archinstaller.log` |

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/logs.png" alt="Logs" width="25"/> Log Files

```bash
~/.archinstaller.log     # Complete installation log
~/.archinstaller.state   # Progress tracking
```

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/contributing.png" alt="Contributing" width="30"/> Contributing

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/how-to.png" alt="How to Contribute" width="25"/> How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

### <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/contribution-types.png" alt="Contribution Types" width="25"/> Contribution Types

- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/bug.png" alt="Bug" width="20"/> **Report bugs**: Open an issue with details
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/feature.png" alt="Feature" width="20"/> **Suggest features**: Describe your use case
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/code.png" alt="Code" width="20"/> **Improve code**: Submit a pull request
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/docs.png" alt="Docs" width="20"/> **Update documentation**: Help others understand the project

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/status.png" alt="Status" width="30"/> Project Status

<div align="center">

| Component | Status | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/status-icon.png" alt="Status Icon" width="20"/> |
|-----------|--------|---------|
| **Core Functionality** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/production.png" alt="Production" width="20"/> Production Ready |
| **Hardware Detection** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/stable.png" alt="Stable" width="20"/> Stable |
| **Gaming Mode** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/tested.png" alt="Tested" width="20"/> Tested |
| **Security Hardening** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/active.png" alt="Active" width="20"/> Active |
| **Documentation** | <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/complete.png" alt="Complete" width="20"/> Complete |

</div>

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/license.png" alt="License" width="30"/> License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

<div align="center">

You are free to use, modify, and distribute this software for personal or commercial purposes.

</div>

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/acknowledgments.png" alt="Acknowledgments" width="30"/> Acknowledgments

- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/arch-linux.png" alt="Arch Linux" width="20"/> Inspired by Arch Linux philosophy: simplicity and user control
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/community.png" alt="Community" width="20"/> Built with community best practices and feedback
- <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/contributors.png" alt="Contributors" width="20"/> Thanks to all contributors and users

---

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/support.png" alt="Support" width="30"/> Support & Contact

<div align="center">

| Platform | Link |
|----------|------|
| **Issues** | [GitHub Issues](https://github.com/GAndromidas/archinstaller/issues) |
| **Discussions** | [GitHub Discussions](https://github.com/GAndromidas/archinstaller/discussions) |
| **Repository** | [github.com/GAndromidas/archinstaller](https://github.com/GAndromidas/archinstaller) |

</div>

---

<div align="center">

## <img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/heart.png" alt="Heart" width="25"/> Made with love for the Arch Linux community

**<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/star.png" alt="Star" width="20"/> If you find this useful, please consider starring the repository!**

[<img src="https://raw.githubusercontent.com/GAndromidas/archinstaller/main/assets/star-button.png" alt="Star Button" width="150"/>](https://github.com/GAndromidas/archinstaller)

</div>