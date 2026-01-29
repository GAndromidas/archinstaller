<div align="center">

# 🚀 Archinstaller

[![Last Commit](https://img.shields.io/github/last-commit/GAndromidas/archinstaller.svg?style=for-the-badge)](https://github.com/GAndromidas/archinstaller/commits/main)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)

**Professional Arch Linux Post-Installation Automation**

Transform your minimal Arch Linux installation into a fully configured, optimized system with intelligent hardware detection and tailored optimizations.

[Installation](#-quick-start) • [Features](#-key-features) • [Modes](#-installation-modes)

</div>

---

## 📋 Overview

**Archinstaller** is a sophisticated post-installation automation tool that intelligently configures Arch Linux based on your hardware. It applies targeted optimizations rather than one-size-fits-all settings, ensuring optimal performance for your specific configuration.

**Core Philosophy:**
- 🎯 **Hardware-Aware** - Detects CPU, GPU, storage, and desktop environment
- 🛡️ **Security-First** - Comprehensive hardening enabled by default
- ⚡ **Performance-Optimized** - Intelligent I/O scheduling and kernel tuning
- 🔄 **Reliable** - Resume functionality for interrupted installations

---

## 🎯 Key Features

### 🔍 System Intelligence & Automation

- **Hardware Detection**
  - Automatically identifies CPU (Intel/AMD) and installs appropriate microcode
  - Detects GPU (NVIDIA/AMD/Intel) and installs correct drivers
  - Optimizes I/O scheduling based on storage type (NVMe/SSD/HDD)
  - Recognizes laptop hardware and enables power-saving features

- **Bootloader Detection & Configuration**
  - Auto-detects installed bootloader (GRUB, systemd-boot, Limine)
  - Applies tailored configuration for each bootloader type
  - GRUB: Snapshot boot entries via grub-btrfs integration
  - systemd-boot: LTS kernel fallback entry management
  - Limine: Configuration support for modern UEFI systems

- **Performance Optimization**
  - Intelligent I/O scheduler selection per storage device type
  - Kernel parameter tuning for optimal responsiveness
  - Parallel package downloads for faster installation

- **Desktop Environment Integration**
  - KDE Plasma: Custom keyboard shortcuts and workspace optimization
  - GNOME: Dark theme, window manager tweaks, and gestures
  - Cosmic: Full environment support and integration
  - Automatic detection and installation of DE-specific packages

### 🛡️ Security & Stability

- **Security Hardening (Enabled by Default)**
  - UFW/Firewalld firewall with secure-by-default policies
  - Fail2ban SSH brute-force protection
  - Sudo password feedback for better UX
  - Automatic port management for installed services (KDE Connect)

- **Btrfs Snapshot System**
  - Full snapshot and recovery solution with Snapper
  - Bootloader integration for easy rollbacks (GRUB, systemd-boot, Limine)
  - GRUB: Automatic snapshot menu via grub-btrfs and grub-btrfsd
  - Limine: Automatic snapshot boot entries via limine-snapper-sync
  - systemd-boot: LTS kernel fallback option for system recovery
  - Automatic snapshot creation before/after package operations
  - GUI management with btrfs-assistant

- **Data Integrity**
  - Automatic filesystem maintenance (fstrim)
  - Package cache optimization (paccache)
  - System log rotation and management

### 🎮 Installation Modes

Choose the perfect setup for your use case:

| Mode | Description | Best For |
|------|-------------|----------|
| **Standard** | Full-featured desktop with all recommended packages | General users, enthusiasts |
| **Minimal** | Lightweight essentials for performance-focused systems | Low-spec hardware, minimal bloat |
| **Server** | Headless configuration with Docker, Portainer, and SSH | Servers, VMs, headless deployments |
| **Custom** | Interactive selection of packages and features | Power users, specific requirements |

### 🎮 Optional Gaming Mode

Transform your system into a gaming powerhouse with one click:

- Steam, Lutris, Heroic Games Launcher
- MangoHud performance overlay
- Goverlay for MangoHud configuration
- GameMode for automatic performance tuning
- ProtonDB game compatibility database

### 🚀 User Experience

- **Interactive Menu System**
  - Beautiful CLI powered by `gum` with elegant fallbacks
  - Clear mode selection with descriptions
  - Confirmation prompts for critical operations

- **Progress Visualization**
  - Real-time progress bars with percentage completion
  - Dynamic time estimation that improves as installation progresses
  - Step-by-step status updates with ✓/✗ indicators

- **Resumable Installations**
  - Automatic progress tracking to `~/.archinstaller.state`
  - Resume from last completed step if interrupted
  - Intelligent handling of failed steps with retry options
  - No data loss, no repeated work

- **Enhanced Terminal Environment**
  - Pre-configured Zsh with Oh-My-Zsh framework
  - Starship prompt for beautiful terminal design
  - Syntax highlighting and auto-completion
  - Custom aliases and productivity plugins

---

### 📊 Supported Platforms

### Hardware
- ✅ **CPU**: Intel, AMD (with appropriate microcode)
- ✅ **GPU**: NVIDIA (including legacy drivers), AMD, Intel
- ✅ **Storage**: NVMe, SSD, HDD (with appropriate optimizations)
- ✅ **Form Factors**: Desktop, Laptop, Virtual Machines (Virt-Manager, QEMU)

### Bootloaders
- ✅ **GRUB** 2.x with Btrfs snapshot support
- ✅ **systemd-boot** with LTS kernel fallback
- ✅ **Limine** (modern UEFI bootloader)

### Desktop Environments
- ✅ **KDE Plasma** 5.x and 6.x
- ✅ **GNOME** 40+
- ✅ **Cosmic** (experimental)

### Base Systems
- ✅ Arch Linux (primary)
- ✅ Arch-based distributions (tested)

---

## 🚀 Quick Start

### Prerequisites

- **Fresh Arch Linux installation** (minimal base system)
- **Active internet connection**
- **User account with sudo privileges**
- **2GB+ free disk space**

### Installation

```bash
# Clone and run
git clone https://github.com/gandromidas/archinstaller.git
cd archinstaller
./install.sh
```

**One-Click Setup:** The installer handles everything automatically - just select your preferred mode and let it configure your system.

### Installation Modes

| Mode | Use Case | Description |
|------|----------|-------------|
| **Standard** | General desktop use | Full-featured setup with all recommended packages |
| **Minimal** | Performance-focused | Lightweight essentials only |
| **Server** | Headless deployments | Docker, SSH, server utilities |
| **Custom** | Power users | Interactive package selection |

### Command-Line Options

```bash
./install.sh [OPTIONS]

OPTIONS:
  -h, --help      Show help message
  -v, --verbose   Enable detailed output
  -q, --quiet     Minimal output mode
  -d, --dry-run   Preview changes only
```

### Installation Experience

The installer provides a professional, user-friendly experience:

```
┌─────────────────────────────────────────────────────────┐
│ Archinstaller - Choose Installation Mode               │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  ▪ Standard     Full-featured desktop setup             │
│  ▪ Minimal      Lightweight essentials                  │
│  ▪ Server       Headless server configuration           │
│  ▪ Custom       Interactive package selection           │
│  ▪ Gaming       Gaming-optimized environment            │
│                                                           │
└─────────────────────────────────────────────────────────┘

✓ System Preparation                    [████████░░] 50%
✓ Shell Setup                           [█████████░] 60%
⟳ Programs Installation                 [██████░░░░] 35%
```

---

## ⚙️ Customization

### Package Management

All packages are organized in `configs/programs.yaml` with logical groupings:

- `common`: Packages installed across all modes
- `essential`: Mode-specific core packages
- `desktop_base`: Desktop environment packages
- `desktop_specific`: DE-specific optimizations
- `server`: Server-mode packages
- `gaming`: Gaming-mode packages

**To customize:**

1. Open `configs/programs.yaml`
2. Add or remove packages from relevant sections
3. No script modification needed
4. Run installer - custom packages will be installed

### Configuration Files

- `.zshrc` — Zsh shell configuration
- `starship.toml` — Starship prompt theme
- `kglobalshortcutsrc` — KDE keyboard shortcuts
- `config.jsonc` — fastfetch system information display
- `gaming_mode.yaml` — Gaming package definitions

---

## 📈 What Gets Installed

### Common Across All Modes

- System utilities and tools
- Development essentials
- Zsh shell with Oh-My-Zsh
- Starship terminal prompt
- System monitoring tools

### Standard Mode

- Full desktop environment (KDE/GNOME/Cosmic)
- Multimedia applications
- Office and productivity tools
- Development tools and IDEs
- Performance monitoring utilities

### Minimal Mode

- Lightweight desktop environment
- Essential command-line tools
- Text editors and basic utilities
- Minimal additional packages

### Server Mode

- Docker and Docker Compose
- SSH server (sshd)
- System service utilities
- Portainer for container management
- Server monitoring tools
- No desktop environment

### Gaming Mode

- Steam platform
- Lutris game launcher
- Heroic Games Launcher
- MangoHud performance overlay
- Goverlay configuration tool
- GameMode for optimization

---

## 🔒 Security Features

### Enabled by Default

✓ **Firewall Configuration**
- UFW with secure-by-default policies
- Deny all incoming, allow all outgoing
- SSH automatically allowed
- Service-aware port management

✓ **SSH Protection**
- Fail2ban with strict SSH policies
- Automatic brute-force detection
- 15-minute ban on suspicious activity

✓ **User Group Configuration**
- Automatic membership in required groups
- Proper permissions for hardware access
- Sudo password feedback enabled

✓ **Bootloader Hardening**
- Bootloader-specific security configurations
- GRUB: Password protection support (optional)
- Secure boot configurations where applicable

✓ **Power Management**
- Power profiles for laptops
- Thermal management (Intel systems)
- Automatic service startup on boot

---

## 📖 Usage Examples

### Install with Standard Mode
```bash
./install.sh
# Select "Standard" from menu
# Let the installer complete
```

### Dry-Run Preview
```bash
./install.sh --dry-run
# See what would be installed without making changes
```

### Verbose Installation
```bash
./install.sh --verbose
# See detailed output of every step
```

### Resume Previous Installation
```bash
./install.sh
# If previous installation detected, choose to resume
# Installer will skip completed steps and continue
```

---

## 🐛 Troubleshooting

### Installation Interrupted

The installer saves progress to `~/.archinstaller.state`. If interrupted:

```bash
./install.sh
# Choose "Resume from last completed step"
# Installation continues seamlessly
```

### No Internet Connection

Archinstaller requires internet to download packages:

```bash
# Check connection
ping archlinux.org

# If failed, fix network first, then rerun
./install.sh
```

### Insufficient Disk Space

Minimum 2GB free space required:

```bash
df -h /
# Check available space
# Free up space if needed
./install.sh
```

### Package Installation Failures

If individual packages fail:

- Installer will skip failed packages and continue
- Check `~/.archinstaller.log` for details
- You can retry later or install manually

---

## 📝 Configuration Files

After installation, customize your system:

### ZSH Configuration
```bash
~/.zshrc              # Main shell configuration
~/.config/starship.toml  # Terminal prompt theme
```

### Bootloader Configuration
```bash
/boot/grub/grub.cfg           # GRUB configuration (auto-generated)
/boot/loader/loader.conf      # systemd-boot configuration
/boot/limine.conf             # Limine bootloader configuration
```

### Btrfs & Snapshots
```bash
/etc/snapper/configs/root                # Snapper snapshot configuration
/etc/default/btrfsmaintenance            # Btrfs maintenance settings
~/.config/btrfs-assistant.conf            # btrfs-assistant GUI settings
```

### Desktop Environment
```bash
~/.config/kglobalshortcutsrc  # KDE shortcuts
~/.config/dconf/user          # GNOME settings
```

### System Information
```bash
~/.config/fastfetch/config.jsonc  # System info display
```

---

## 📋 Installation Log

Full installation logs are saved for reference:

```bash
~/.archinstaller.log     # Complete installation log
~/.archinstaller.state   # Progress tracking
```

Check logs if you need to:
- Troubleshoot issues
- See what was installed
- Verify system changes

## 🔧 Bootloader Integration Details

### GRUB
- **Auto-detection**: Checks `/boot/grub`, `/boot/grub2`, and pacman packages
- **Btrfs Integration**: Uses `grub-btrfs` for automatic snapshot boot entries
- **Daemon**: Runs `grub-btrfsd` for dynamic menu updates
- **Configuration**: `/boot/grub/grub.cfg` (auto-regenerated)

### systemd-boot
- **Auto-detection**: Checks `/boot/loader/entries` and bootctl availability
- **LTS Fallback**: Automatically creates LTS kernel boot entry
- **Configuration**: `/boot/loader/loader.conf` and `/boot/loader/entries/`
- **Kernel Parameters**: Applied to all boot entries automatically

### Limine
- **Auto-detection**: Checks `/boot/limine`, `/boot/EFI/limine`, and pacman packages
- **Btrfs Integration**: Uses `limine-snapper-sync` for automatic snapshot boot entries
- **Snapshot Service**: Runs `limine-snapper-sync.service` for dynamic snapshot menu updates
- **Configuration**: `/boot/limine.conf` with timeout and default entry settings
- **Modern UEFI**: Full support for modern UEFI-only systems
- **Snapshot Boot Entries**: Auto-generated and synchronized with Snapper configuration

---

## 🤝 Contributing

Contributions are welcome! Whether you want to:

- **Report bugs**: Open an issue with details
- **Suggest features**: Describe your use case
- **Improve code**: Submit a pull request
- **Update documentation**: Help others understand the project

### How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📊 Project Status

| Component | Status |
|-----------|--------|
| **Core Functionality** | ✅ Production Ready |
| **Hardware Detection** | ✅ Stable |
| **Gaming Mode** | ✅ Tested |
| **Security Hardening** | ✅ Active |
| **Documentation** | ✅ Complete |

---

## 📜 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

You are free to use, modify, and distribute this software for personal or commercial purposes.

---

## 🙏 Acknowledgments

- Inspired by Arch Linux philosophy: simplicity and user control
- Built with community best practices and feedback
- Thanks to all contributors and users

---

## 📞 Support & Contact

- **Issues**: [GitHub Issues](https://github.com/gandromidas/archinstaller/issues)
- **Discussions**: [GitHub Discussions](https://github.com/gandromidas/archinstaller/discussions)
- **Repository**: [github.com/gandromidas/archinstaller](https://github.com/gandromidas/archinstaller)

---

<div align="center">

**Made with ❤️ for the Arch Linux community**

⭐ If you find this useful, please consider starring the repository!

</div>