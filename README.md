# ArchInstaller

**Automated, hardware-aware post-installation setup for Arch Linux and EndeavourOS.**

ArchInstaller turns a fresh, minimal Arch install into a fully configured, optimized
desktop or server in one guided run. It detects your CPU, GPU, storage type, laptop
model, desktop environment, and bootloader, then applies targeted configuration for
*your* hardware instead of generic one-size-fits-all settings — and it's safe to
re-run if something is interrupted.

```
./install.sh
```

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Installation modes](#installation-modes)
- [Command-line options](#command-line-options)
- [What it does, step by step](#what-it-does-step-by-step)
- [Project structure](#project-structure)
- [Configuration files](#configuration-files)
- [Resuming an interrupted install](#resuming-an-interrupted-install)
- [Logs](#logs)
- [Safety model](#safety-model)
- [Troubleshooting](#troubleshooting)
- [Testing / development](#testing--development)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- **Hardware-aware CPU tuning** — Intel/AMD detection with the correct microcode package
- **Automatic GPU driver installation** — AMD/Intel, picks the right driver stack
- **Storage-aware I/O tuning** — NVMe/SSD/HDD get the appropriate scheduler
- **Desktop environment detection** — KDE Plasma 6+, GNOME 46+, Cosmic get DE-specific tweaks
- **Laptop detection and optimization** — manufacturer/model-aware power and function-key handling
- **Security hardening** — UFW or Firewalld, plus Fail2ban with SSH jail protection
- **Gaming Mode** (optional) — Steam, Wine, GameMode, MangoHud, Goverlay, Heroic, LACT (AMD GPU control), and multilib setup
- **Smart AMD P-State handling** with gaming-aware governor selection
- **Wake-on-LAN configuration** for wired desktops
- **Zsh + Oh My Zsh + Starship prompt**, pre-configured
- **Three bootloaders supported** — GRUB, systemd-boot, and Limine — each with tuned timeouts and kernel params
- **Resumable installs** — re-running after an interruption skips completed steps
- **Dry-run mode** — preview every step with no changes made to your system

## Requirements

- A fresh Arch Linux or EndeavourOS installation
- An active internet connection
- A regular (non-root) user account with `sudo` privileges
- At least 2 GB of free disk space
- One of the supported bootloaders already installed: GRUB, systemd-boot, or Limine

## Quick start

```bash
git clone https://github.com/GAndromidas/archinstaller.git
cd archinstaller
./install.sh
```

You'll be walked through an interactive menu to pick an installation mode, and
prompted before anything destructive (bootloader/kernel changes) happens. Everything
else proceeds automatically with progress shown in a live dashboard.

Want to see what would happen first, with zero changes to your system?

```bash
./install.sh --dry-run
```

## Installation modes

| Mode         | Best for                              | What you get                                             |
|--------------|----------------------------------------|-----------------------------------------------------------|
| **Standard** | Intermediate users, daily-driver setups | Full package set, all recommended tools and optimizations |
| **Minimal**  | New users, lightweight installs        | Essential tools only, smaller footprint                   |
| **Server**   | Headless machines                       | SSH, Docker-ready, server utilities — no desktop packages, no Gaming Mode |

Gaming Mode is offered as an optional extra step during Standard/Minimal installs
(it's skipped automatically in Server mode).

## Command-line options

```
-h, --help      Show the help message and exit
-v, --verbose   Enable verbose output (show all package installation details)
-q, --quiet     Quiet mode (minimal output)
-d, --dry-run   Preview what will be installed without making changes
-a, --auto      Automatically select the recommended installation mode
-y, --yes       Non-interactive mode: accept safe/default prompts automatically
```

`--yes` will never trigger the final automatic reboot — it always leaves that
decision to you. Destructive/irreversible choices (like bootloader and kernel
parameter changes) are still confirmed interactively even in `--yes` mode.

```bash
./install.sh --auto --yes     # fully unattended, recommended mode, no reboot prompt
./install.sh --verbose        # see full package manager output as it happens
```

## What it does, step by step

The installer runs 10 steps end to end, shown live in the dashboard. Steps marked
*(ask)* pause for confirmation before making changes:

| # | Step | Notes |
|---|------|-------|
| 1 | System Preparation *(ask)* | Mirrors, multilib repo, pacman tuning, locale generation |
| 2 | Shell Setup | Zsh, Oh My Zsh, Starship |
| 3 | Yay Installation | AUR helper build |
| 4 | Programs Installation | Mode- and DE-specific package set from `configs/programs.yaml` |
| 5 | Gaming Mode *(optional)* | Skipped in Server mode; declining is not treated as a failure |
| 6 | Bootloader & Kernel Configuration *(ask)* | GRUB / systemd-boot / Limine, kernel params, initramfs |
| 7 | System Services | CPU/GPU/storage tuning, laptop optimizations, memory/zram tuning |
| 8 | Fail2ban Setup | SSH jail protection |
| 9 | Wake-on-LAN Configuration | Wired desktops only |
| 10 | Maintenance | Cleanup, orphan removal, final system checks |

## Project structure

```
archinstaller/
├── install.sh                    # Entry point: argument parsing, menu, step orchestration
├── configs/                      # Config files copied/applied during setup
│   ├── programs.yaml             #   package lists per mode/desktop environment
│   ├── gaming_mode.yaml          #   gaming package list
│   ├── config.jsonc              #   app config
│   ├── MangoHud.conf             #   MangoHud overlay defaults
│   ├── starship.toml             #   Starship prompt theme
│   └── .zshrc                    #   default Zsh config
├── scripts/
│   ├── common.sh                 # Shared helpers: menus, logging, summaries, multilib, etc.
│   ├── lib/                      # Core libraries
│   │   ├── core.sh               #   base logging/step primitives
│   │   ├── ui.sh                 #   confirm/prompt helpers (gum + plain-text fallback)
│   │   ├── dashboard.sh          #   live progress dashboard
│   │   ├── package.sh            #   pacman/AUR/Flatpak install helpers + retry logic
│   │   ├── system.sh             #   hardware detection (CPU, laptop, etc.)
│   │   ├── config.sh             #   YAML config loading (yq-based, with fallback)
│   │   └── state.sh              #   resumable step-state tracking
│   ├── modules/                  # One file per installation step (see table above)
│   │   ├── system_preparation.sh
│   │   ├── shell_setup.sh
│   │   ├── yay.sh
│   │   ├── programs.sh
│   │   ├── gaming_mode.sh
│   │   ├── bootloader_config.sh
│   │   ├── system_services.sh
│   │   ├── fail2ban.sh
│   │   ├── wakeonlan_config.sh
│   │   └── maintenance.sh
│   └── verify.sh                 # Post-reboot verification (read-only, run after rebooting)
├── tests/
│   └── syntax.sh                 # Dependency-free `bash -n` smoke test for every script
├── LICENSE
└── README.md
```

`scripts/modules/` is the single source of truth for every installation step —
there are no duplicate/legacy copies elsewhere in the tree.

## Configuration files

- **`configs/programs.yaml`** — the package list. Grouped by installation mode and
  desktop environment, each entry has a name and a short description shown during
  install. Edit this to add/remove packages from your own installs.
- **`configs/gaming_mode.yaml`** — the Gaming Mode package list, same format.
- **`configs/config.jsonc`**, **`configs/MangoHud.conf`**, **`configs/starship.toml`**,
  **`configs/.zshrc`** — dotfiles/app configs applied as part of Shell Setup /
  Gaming Mode.

YAML lists are parsed with [`yq`](https://github.com/mikefarah/yq) when available;
the installer falls back to a plain-text parser if `yq` isn't installed, so no
extra setup is required.

## Resuming an interrupted install

Progress is tracked in `/var/tmp/archinstaller.state`. If the installer is
interrupted (power loss, closed terminal, `Ctrl+C`), just run `./install.sh` again
— completed steps are detected and skipped automatically. (This state file is not
written in `--dry-run` mode.)

## Logs

| File | Contents |
|------|----------|
| `/var/tmp/archinstaller.log` | Full installation log — every command's output |
| `/var/tmp/archinstaller.state` | Step-by-step progress, used for resuming |

If something fails, the log is the first place to look — the dashboard shows a
short summary, but the log has full command output for the failing step.

## Verifying the install after reboot

The install log only shows what happened *during* setup — it can't confirm
things that only make sense on a fully booted system: whether the bootloader
actually works on a cold boot, whether the GPU driver actually loaded,
whether fail2ban's SSH jail is active under real (low) load, whether
Wake-on-LAN survived the reboot, whether snapshots actually mounted.

After rebooting, run:

```bash
bash scripts/verify.sh          # summary
bash scripts/verify.sh --verbose  # with extra detail (cmdline, driver names, etc.)
```

It's entirely read-only — no writes, safe to run any time, as many times as
you like. It checks boot mode, kernel params, CPU/GPU drivers, storage
scheduler, firewall/fail2ban's actual live state, Wake-on-LAN, shell setup,
and (if installed) gaming tools, then prints a pass/warning/fail summary.

## Safety model

- **Nothing destructive happens without confirmation.** Steps that touch disk
  partitioning-adjacent things (bootloader config, kernel parameters) always pause
  for an explicit yes/no, even in `--yes` mode.
- **`--yes` never auto-reboots.** You always get to choose when to reboot.
- **`--dry-run` makes zero changes.** Every module has a hard preview guard at the
  top that prints what it *would* do and exits before touching your system.
- **Idempotent by design.** Config file edits (pacman.conf, GRUB, systemd-boot
  entries, sysctl, etc.) check for existing entries before writing, so re-running
  the installer doesn't produce duplicate config blocks.
- **Declining optional steps isn't a failure.** Gaming Mode, for example, can be
  skipped without affecting the rest of the install or being reported as an error.

## Troubleshooting

**The installer stopped partway through.**
Check `/var/tmp/archinstaller.log` for the failing step's output, fix the
underlying issue (usually a network blip or a package no longer in the
repos/AUR), then just re-run `./install.sh` — it resumes from where it left off.

**A package failed to install.**
Transient pacman/AUR failures (locked database, flaky mirror) are retried
automatically a few times before being reported as a failure. If a specific
package genuinely fails, it's listed in the final summary; everything else still
gets installed.

**I want to start over from scratch.**
Delete the state file and re-run: `rm /var/tmp/archinstaller.state`.

**`gum` isn't installed / I'm in a bare terminal.**
The installer works without `gum` — menus and prompts fall back to plain
`read`-based text prompts automatically.

## Testing / development

A dependency-free syntax smoke test is included:

```bash
bash tests/syntax.sh
```

This runs `bash -n` across every script in the repository. It's intentionally
simple (no external dependencies) so it can run anywhere, including CI.

For deeper static analysis during development, [ShellCheck](https://www.shellcheck.net/)
is recommended:

```bash
shellcheck -x scripts/**/*.sh install.sh
```

## Contributing

Issues and pull requests are welcome. A few guidelines:

- Keep `scripts/modules/` as the single source of truth for step logic — no
  parallel/duplicate copies.
- Run `bash tests/syntax.sh` and ShellCheck before opening a PR.
- New config-file edits should be idempotent (check before writing) to keep
  re-runs safe.
- Prefer extending `scripts/common.sh` / `scripts/lib/` for logic shared across
  more than one module, rather than copy-pasting.

## License

MIT — see [LICENSE](LICENSE).
