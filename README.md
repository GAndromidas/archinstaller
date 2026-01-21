<div align="center">

# 🚀 Archinstaller

[![Last Commit](https://img.shields.io/github/last-commit/GAndromidas/archinstaller.svg?style=for-the-badge)](https://github.com/GAndromidas/archinstaller/commits/main)
[![Latest Release](https://img.shields.io/github/v/release/GAndromidas/archinstaller.svg?style=for-the-badge)](https://github.com/GAndromidas/archinstaller/releases)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)

**Advanced Arch Linux Post-Installation Automation**

Transform your minimal Arch Linux installation into a fully configured, optimized, and ready-to-use system in minutes.

[Installation](#-quick-start) • [Features](#-key-features) • [Modes](#-installation-modes) • [Contributing](#-contributing)

</div>

---

## 📋 Overview

**Archinstaller** is a sophisticated post-installation automation script for Arch Linux that intelligently configures your system based on detected hardware. Rather than applying one-size-fits-all configurations, it inspects your CPU, GPU, storage type, and desktop environment to apply tailored optimizations and security hardening.

Built on the Arch Linux philosophy of **simplicity and minimalism**, Archinstaller delivers a professional installation experience with:

- 🎯 Real-time progress tracking with time estimation
- 🔄 Intelligent resume functionality for interrupted installations
- 🛡️ Security hardening enabled by default
- ⚡ Hardware-aware performance optimizations
- 🎮 Optional gaming mode for complete gaming setup

---

## ✨ Core Philosophy

**Intelligent Automation** — Rather than forcing you to make countless manual decisions, Archinstaller analyzes your system and applies best-practice configurations that typically require hours of manual research and tweaking.

---

## 🎯 Key Features

### 🔍 System Intelligence & Automation

- **Hardware Detection**
  - Automatically identifies CPU (Intel/AMD) and installs appropriate microcode
  - Detects GPU (NVIDIA/AMD/Intel) and installs correct drivers
  - Optimizes I/O scheduling based on storage type (NVMe/SSD/HDD)
  - Recognizes laptop hardware and enables power-saving features

- **Performance Optimization**
  - Dynamic ZRAM swap configuration based on available memory
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
  - Bootloader integration for easy rollbacks
  - LTS kernel fallback option for system recovery

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

## 📊 Supported Platforms

### Hardware
- ✅ **CPU**: Intel, AMD (with appropriate microcode)
- ✅ **GPU**: NVIDIA (including legacy drivers), AMD, Intel
- ✅ **Storage**: NVMe, SSD, HDD (with appropriate optimizations)
- ✅ **Form Factors**: Desktop, Laptop, Virtual Machines (Virt-Manager, QEMU)

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

Before running Archinstaller, ensure you have:

- A **fresh, minimal Arch Linux installation**
- An **active internet connection** (required for downloading packages)
- A **regular user account** with `sudo` privileges
- At least **2GB free disk space**

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/gandromidas/archinstaller.git
   cd archinstaller
   ```

2. **Review the installation modes (optional):**
   ```bash
   ./install.sh --help
   ```

3. **Run the installer:**
   ```bash
   ./install.sh
   ```

4. **Select your installation mode:**
   - Interactive menu will guide you through the process
   - Choose: Standard, Minimal, Server, or Custom
   - Confirm and let the installer work

5. **After installation:**
   - System will be fully configured and optimized
   - Reboot to apply all changes
   - Enjoy your new Arch system!

### Command-Line Options

```bash
./install.sh [OPTIONS]

OPTIONS:
  -h, --help      Show help message and exit
  -v, --verbose   Enable verbose output (show all package details)
  -q, --quiet     Quiet mode (minimal output)
  -d, --dry-run   Preview changes without applying them
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
- ZRAM swap optimization
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