#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$SCRIPT_DIR/../configs"
source "$SCRIPT_DIR/common.sh"

# Function to get full desktop environment version
get_desktop_version() {
    local desktop="$1"
    local version=""

    case "$desktop" in
        "KDE"|"kde"|"plasma"|"Plasma")
            # Method 1: Check plasmashell version (most reliable) - supports Plasma 6.6+
            if command -v plasmashell >/dev/null; then
                version=$(plasmashell --version 2>/dev/null | grep -o "Plasma [0-9.]*" | head -1)
                if [ -n "$version" ]; then
                    echo "$version"
                    return 0
                fi
            fi

            # Method 2: Check plasma-workspace package (more accurate for Plasma 6.6+)
            if command -v pacman >/dev/null; then
                version=$(pacman -Q plasma-workspace 2>/dev/null | grep -o "[0-9.]*" | head -1)
                if [ -n "$version" ]; then
                    echo "Plasma $version"
                    return 0
                fi
                # Fallback to plasma-desktop for older installations
                version=$(pacman -Q plasma-desktop 2>/dev/null | grep -o "[0-9.]*" | head -1)
                if [ -n "$version" ]; then
                    echo "Plasma $version"
                    return 0
                fi
            fi

            # Method 3: Check environment variables
            if [ -n "${KDE_SESSION_VERSION:-}" ]; then
                echo "Plasma $KDE_SESSION_VERSION.x"
                return 0
            fi

            # Fallback
            echo "Plasma (version unknown)"
            ;;
        "GNOME"|"gnome")
            # Method 1: Check gnome-shell version - supports GNOME 50
            if command -v gnome-shell >/dev/null; then
                version=$(gnome-shell --version 2>/dev/null | grep -o "GNOME Shell [0-9.]*" | head -1)
                if [ -n "$version" ]; then
                    echo "$version"
                    return 0
                fi
            fi

            # Method 2: Check GNOME packages
            if command -v pacman >/dev/null; then
                version=$(pacman -Q gnome-shell 2>/dev/null | grep -o "[0-9.]*" | head -1)
                if [ -n "$version" ]; then
                    echo "GNOME $version"
                    return 0
                fi
            fi

            # Method 3: Check GNOME session version
            if [ -n "${GNOME_DESKTOP_SESSION_ID:-}" ]; then
                # Try to extract version from session
                if command -v gsettings >/dev/null; then
                    version=$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | grep -o "[0-9.]*" | head -1)
                    if [ -n "$version" ]; then
                        echo "GNOME $version"
                        return 0
                    fi
                fi
            fi

            # Fallback
            echo "GNOME (version unknown)"
            ;;
        "COSMIC"|"cosmic")
            # Method 1: Check cosmic-comp version (Cosmic 1+)
            if command -v cosmic-comp >/dev/null; then
                version=$(cosmic-comp --version 2>/dev/null | grep -o "COSMIC [0-9.]*" | head -1)
                if [ -n "$version" ]; then
                    echo "$version"
                    return 0
                fi
            fi

            # Method 2: Check cosmic packages - updated for Cosmic 1+
            if command -v pacman >/dev/null; then
                # Check for cosmic-session package (primary package for Cosmic 1+)
                version=$(pacman -Q cosmic-session 2>/dev/null | grep -o "[0-9.]*" | head -1)
                if [ -n "$version" ]; then
                    echo "COSMIC $version"
                    return 0
                fi
                # Check for cosmic-desktop package
                version=$(pacman -Q cosmic-desktop 2>/dev/null | grep -o "[0-9.]*" | head -1)
                if [ -n "$version" ]; then
                    echo "COSMIC $version"
                    return 0
                fi
                # Check for cosmic-comp package (compositor)
                version=$(pacman -Q cosmic-comp 2>/dev/null | grep -o "[0-9.]*" | head -1)
                if [ -n "$version" ]; then
                    echo "COSMIC $version"
                    return 0
                fi
            fi

            # Method 3: Check environment variables
            if [ -n "${COSMIC_SESSION_VERSION:-}" ]; then
                echo "COSMIC $COSMIC_SESSION_VERSION"
                return 0
            fi

            # Method 4: Check for cosmic process
            if pgrep -f "cosmic" >/dev/null; then
                echo "COSMIC (version unknown)"
                return 0
            fi

            # Fallback
            echo "COSMIC (version unknown)"
            ;;
        *)
            echo "$desktop (version unknown)"
            ;;
    esac
}

setup_shell() {
  step "Setting up ZSH shell environment"

  # Ensure $HOME exists (should always be true, but guard against weird subshell envs)
  if [ ! -d "$HOME" ]; then
    log_error "\$HOME directory does not exist: $HOME"
    return 1
  fi

  # Copy Starship prompt configuration
  local src_starship="$CONFIGS_DIR/starship.toml"
  local dst_starship="$HOME/.config/starship.toml"

  if [ -f "$src_starship" ]; then
    mkdir -p "$HOME/.config"
    log_info "Copying starship.toml: $src_starship -> $dst_starship"
    if cp "$src_starship" "$dst_starship"; then
      log_success "Starship prompt configuration copied to $dst_starship"
    else
      log_error "Failed to copy starship.toml" "cp exit code: $?"
    fi
  else
    log_warning "Source starship.toml not found at $src_starship"
  fi

  # Install Oh-My-Zsh
  if [ ! -d "$HOME/.oh-my-zsh" ]; then
    log_info "Installing Oh-My-Zsh framework..."
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes yes | \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" >>"$INSTALL_LOG" 2>&1 || true

    if [ -d "$HOME/.oh-my-zsh" ]; then
      log_success "Oh-My-Zsh installed successfully"
    else
      log_warning "Oh-My-Zsh installation may have failed"
    fi
  else
    log_info "Oh-My-Zsh already installed"
  fi

  # Overwrite .zshrc AFTER Oh-My-Zsh so our config always wins
  local src_zshrc="$CONFIGS_DIR/.zshrc"
  local dst_zshrc="$HOME/.zshrc"

  if [ -f "$src_zshrc" ]; then
    log_info "Copying .zshrc: $src_zshrc -> $dst_zshrc"
    if cp "$src_zshrc" "$dst_zshrc"; then
      log_success "ZSH configuration copied to $dst_zshrc"
    else
      log_error "Failed to copy .zshrc" "cp exit code: $?"
    fi
  else
    log_warning "Source .zshrc not found at $src_zshrc"
  fi

  # Change default shell to ZSH
  log_info "Setting ZSH as default shell..."
  if sudo chsh -s "$(command -v zsh)" "$USER" 2>/dev/null; then
    log_success "Default shell changed to ZSH"
  else
    log_warning "Failed to change default shell. You may need to do this manually."
  fi

}

# Main execution
setup_shell
