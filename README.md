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
| **GRUB** | Snapshot entries, timeout optimization | grub-btrfs + grub-btrfsd |
| **systemd-boot** | LTS kernel fallback, EFI support | Automatic entry management |
| **Limine** | Modern UEFI, fast boot | limine-snapper-sync |

#### Advanced Performance Optimization (CachyOS-Inspired)

- **Smart Memory Management**: Dynamic swappiness based on system RAM (1-3GB: 10, 4-7GB: 10, 8-15GB: 5, 16GB+: 1)
- **Intelligent Storage Optimization**: Automatic I/O scheduler detection (NVMe: none, SSD: deadline, HDD: mq-deadline)
- **Advanced Kernel Tuning**: Process scheduling, network stack optimization, filesystem-specific tuning
- **Hardware-Aware Configuration**: NVMe detection, zRAM monitoring, virtualization awareness
- **Transparent Hugepages**: Disabled for desktop systems to improve performance
- **Persistent Settings**: All optimizations survive reboots via udev rules and systemd services

#### Performance Optimization
- **I/O Scheduling**: Automatic selection based on storage type
- **Kernel Tuning**: `vm.swappiness=10`, `fs.inotify.max_user_watches=524288`
- **Parallel Downloads**: Pacman parallel package fetching
- **Memory Management**: ZRAM compression + swap optimization

#### Desktop Environment Integration
| Environment | Optimizations | Features |
|-------------|---------------|----------|
| **KDE Plasma 6+** | Qt6-based shortcuts, fullscreen automation | kglobalshortcutsrc + Konsole fullscreen |
| **GNOME 46+** | Latest dark theme, modern tweaks | dconf settings + current extensions |
| **Cosmic** | Latest alpha builds support | Experimental DE integration |

### Security & Stability

#### Security Hardening (Enabled by Default)
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

#### Btrfs Snapshot System
- **Full Solution**: Snapper + bootloader integration
- **Automatic Snapshots**: Before/after package operations
- **GUI Management**: btrfs-assistant for easy rollback
- **Boot Integration**: GRUB/systemd-boot/Limine snapshot entries

### Smart AMD P-State System (NEW)

Intelligent CPU power management that automatically detects your system configuration:

#### Detection Methods
- **CPU Vendor Detection**: Intel vs AMD identification
- **P-State Support Validation**: 3-method validation (sysfs, CPU capabilities, kernel version)
- **Gaming Mode Detection**: 5-indicator system with 50% threshold
- **Automatic Fallback**: Graceful degradation if configuration fails

#### Configuration Logic
| System Type | Detection | P-State Configuration | Performance Profile |
|-------------|------------|---------------------|-------------------|
| **Gaming Mode** | Zen kernel + gaming tools + services | Maximum performance (performance governor) |
| **Standard System** | Regular desktop configuration | Balanced performance (power management) |
| **Unsupported** | Zen 1 CPUs or older systems | ACPI CPUfreq fallback |

### Gaming Mode (Optional)

Transform your system into a gaming powerhouse with one click:

| Component | Description |
|-----------|-------------|
| **Steam** | Native gaming platform with Proton |
| **Heroic Games Launcher** | Epic Games + GOG support |
| **Faugus Launcher** | Game management and launcher |
| **MangoHud** | Performance overlay and monitoring |
| **Goverlay** | MangoHud configuration GUI |
| **GameMode** | Automatic performance tuning |
| **Wine** | Windows compatibility layer |
| **Zen Kernel** | Optimized for gaming performance |
| **Note**: AMD P-State handled automatically by system_services.sh |

### Smart Peripheral Detection

Automatically detects connected peripherals and installs appropriate management software:

| Peripheral | Detection | Software |
|------------|------------|----------|
| **Logitech Devices** | USB vendor ID | Solaar (Unifying Receiver) |
| **Keychron Keyboards** | Device name | VIA-bin (keyboard configuration) |
| **Gaming Mice** | HID detection | libratbag + Piper |
| **Razer Devices** | Vendor ID | OpenRazer + Polychromatic |
| **Generic HID** | USB/HID tree | hidapi + udev rules |

---

## Installation Modes

Choose the perfect setup for your use case:

| Mode | Use Case | Requirements |
|------|-------------|-------------|
| **Standard** | Full-featured desktop | General users, enthusiasts |
| **Minimal** | Lightweight essentials | Low-spec hardware, minimal bloat |
| **Server** | Headless configuration | Docker, SSH, server utilities |
| **Custom** | Interactive selection | Power users, specific requirements |
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
custom:          # Optional additions
```

**Easy Customization:**

1. Open `configs/programs.yaml`
2. Add/remove packages from relevant sections
3. No script modification needed
4. Run installer - custom packages installed automatically

### Configuration Files

| File | Purpose |
|------|---------|
| `.zshrc` | Zsh shell configuration |
| `starship.toml` | Starship prompt theme |
| `kglobalshortcutsrc` | KDE keyboard shortcuts |
| `config.jsonc` | Fastfetch system info |
| `gaming_mode.yaml` | Gaming package definitions |

---

## What Gets Installed

### Common Across All Modes

- System utilities and tools
- Development essentials
- Zsh shell with Oh-My-Zsh
- Starship terminal prompt
- System monitoring tools

### Mode-Specific Packages

| Mode | Desktop | Applications | Tools |
|------|-------------|-------------|------|
| **Standard** | Full DE (KDE/GNOME/Cosmic) | Multimedia, Office, IDEs | Performance monitoring |
| **Minimal** | Lightweight DE | Essential apps only | Basic utilities |
| **Server** | No DE | Docker, Portainer | Server utilities |
| **Gaming** | Gaming-optimized DE | Steam, Heroic Games Launcher, Faugus Launcher, Wine | Performance tools |

---

## Security Features

### Enabled by Default

| Feature | Status | Configuration |
|---------|--------|---------------|
| **Firewall** | Active | UFW/Firewalld with secure policies |
| **SSH Protection** | Active | Fail2ban with strict policies |
| **User Groups** | Active | Proper permissions configured |
| **Bootloader** | Active | Security-hardened configuration |

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

- **GRUB** 2.x with Btrfs snapshot support
- **systemd-boot** with LTS kernel fallback
- **Limine** (modern UEFI bootloader)

### Desktop Environments

- **KDE Plasma** 6.x (Qt6-based) - bleeding edge only
- **GNOME** 46+ (latest stable)
- **Cosmic** (experimental, latest builds)

---

## Laptop Optimizations

### Intelligent Laptop Detection & Optimization

Archinstaller provides **manufacturer-specific optimizations** for 15+ laptop brands with automatic detection and tailored configuration.

#### Supported Manufacturers

| Brand | Gaming Detection | Special Features |
|-------|------------------|-----------------|
| **Lenovo** | Legion, ThinkPad Gaming | thinkpad_acpi, lenovo-legion-tool, thinkfan |
| **HP** | Omen, Pavilion Gaming | hp-wmi, omen-monitors, elitebook support |
| **Dell** | Alienware, XPS Gaming | dell-wmi, dell-xps-firmware, alienware tools |
| **Acer** | Predator, Nitro Gaming | acer-wmi, acer-nitro-optimizer, swift support |
| **ASUS** | ROG, TUF Gaming | asus-wmi, asusctl, supergfxctl, zenbook support |
| **MSI** | GE, GT, GL Gaming | msi-wmi, msi-ec, msi-per-keyboard, creator support |
| **Razer** | Blade Gaming | razer-specific optimizations |
| **LG** | Gram Ultra-light | lg-specific power management |
| **Samsung** | Galaxy Book | samsung-specific optimizations |
| **Huawei** | MateBook | huawei-specific features |
| **Xiaomi** | Mi/RedmiBook | xiaomi-specific optimizations |
| **Framework** | Modular Laptops | framework-specific features |
| **System76** | Linux-native | system76 firmware support |
| **Microsoft** | Surface | surface pen/touch support |

#### Automatic Features

**Gaming Laptop Detection:**
- Automatic identification of gaming variants
- Gaming-specific thermal management
- Performance profile optimization
- RGB lighting support (where applicable)

**Power Management:**
- Intel: thermald + Intel P-State driver
- AMD: AMD P-State configuration
- Universal: power-profiles-daemon or tuned-ppd

**Function Keys & Hotkeys:**
- Manufacturer-specific WMI module loading
- Brightness, volume, WiFi toggle support
- Special function key mapping

#### Usage

**Interactive Mode:**
```bash
./install.sh
# Script will detect your laptop and show available optimizations
```

**Automatic Mode:**
```bash
export AUTO_LAPTOP_OPTS=true
./install.sh
# Automatically applies all detected optimizations
```

**Check Detection:**
```bash
# Test laptop detection before running
bash -c 'source scripts/system_services.sh && detect_laptop_manufacturer && get_laptop_model'
```

#### What Gets Optimized

1. **Power Profile Management**
   - power-profiles-daemon (preferred) or tuned-ppd
   - Automatic power mode switching
   - Battery vs AC power optimization

2. **CPU-Specific Optimizations**
   - Intel: thermald for thermal management
   - AMD: P-State driver configuration
   - CPU frequency scaling

3. **Manufacturer-Specific Tools**
   - Brand-specific function key support
   - Gaming laptop optimizations (when detected)
   - ACPI event handling

4. **System Integration**
   - ACPI daemon for hardware events
   - Battery monitoring and management
   - Suspend/resume functionality

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

#### Advanced Performance & Smart CPU Management
- **🚀 CachyOS-Inspired Optimizations**: Advanced memory management, intelligent storage optimization, hardware-aware configuration
- **🧠 Smart AMD P-State System**: Automatic gaming vs system detection with 3-method validation and fallback mechanisms
- **📊 Dynamic Resource Management**: RAM-based swappiness, storage-type I/O scheduling, filesystem-specific tuning
- **🛡️ Robust Error Handling**: Automatic fallbacks and graceful degradation for unsupported systems
- **⚡ Persistent Configuration**: All optimizations survive reboots via udev rules and systemd services

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