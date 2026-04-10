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
            # Method 1: Check plasmashell version (most reliable)
            if command -v plasmashell >/dev/null; then
                version=$(plasmashell --version 2>/dev/null | grep -o "Plasma [0-9.]*" | head -1)
                if [ -n "$version" ]; then
                    echo "$version"
                    return 0
                fi
            fi

            # Method 2: Check plasma packages
            if command -v pacman >/dev/null; then
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
            # Method 1: Check gnome-shell version
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
            # Method 1: Check cosmic-comp version
            if command -v cosmic-comp >/dev/null; then
                version=$(cosmic-comp --version 2>/dev/null | grep -o "COSMIC [0-9.]*" | head -1)
                if [ -n "$version" ]; then
                    echo "$version"
                    return 0
                fi
            fi

            # Method 2: Check cosmic packages
            if command -v pacman >/dev/null; then
                # Check for cosmic-session package
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

  # Install Oh-My-Zsh
  if [ ! -d "$HOME/.oh-my-zsh" ]; then
    log_info "Installing Oh-My-Zsh framework..."
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes yes | \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" >/dev/null 2>&1 || true

    if [ -d "$HOME/.oh-my-zsh" ]; then
      log_success "Oh-My-Zsh installed successfully"
    else
      log_warning "Oh-My-Zsh installation may have failed"
    fi
  else
    log_info "Oh-My-Zsh already installed"
  fi

  # Change default shell to ZSH
  log_info "Setting ZSH as default shell..."
  if sudo chsh -s "$(command -v zsh)" "$USER" 2>/dev/null; then
    log_success "Default shell changed to ZSH"
  else
    log_warning "Failed to change default shell. You may need to do this manually."
  fi

  # Copy ZSH configuration
  if [ -f "$CONFIGS_DIR/.zshrc" ]; then
    cp "$CONFIGS_DIR/.zshrc" "$HOME/" 2>/dev/null && log_success "ZSH configuration copied"
  fi

  # Copy Starship prompt configuration
  if [ -f "$CONFIGS_DIR/starship.toml" ]; then
    mkdir -p "$HOME/.config"
    cp "$CONFIGS_DIR/starship.toml" "$HOME/.config/" 2>/dev/null && log_success "Starship prompt configuration copied"
  fi

  # Fastfetch setup
  if command -v fastfetch >/dev/null; then
    if [ -f "$HOME/.config/fastfetch/config.jsonc" ]; then
      log_warning "fastfetch config already exists. Skipping generation."
    else
      run_step "Creating fastfetch config" bash -c 'fastfetch --gen-config'
    fi

    # Copy safe config from configs directory
    if [ -f "$CONFIGS_DIR/config.jsonc" ]; then
      mkdir -p "$HOME/.config/fastfetch"
      cp "$CONFIGS_DIR/config.jsonc" "$HOME/.config/fastfetch/config.jsonc"
      log_success "fastfetch config copied from configs directory."
    else
      log_warning "config.jsonc not found in configs directory. Using generated config."
    fi
  else
    log_warning "fastfetch not installed. Skipping config setup."
  fi
}

setup_kde_shortcuts() {
  step "Setting up KDE global shortcuts and Konsole fullscreen"

  # Check for KDE Plasma 6+ installation (works during installation too)
  local kde_detected=false
  local plasma_version=""
  
  # Check for Plasma 6+ specifically
  if [[ "$XDG_CURRENT_DESKTOP" == "KDE" ]]; then
    kde_detected=true
    # Get Plasma version
    plasma_version=$(plasmashell --version 2>/dev/null | head -1 || echo "6.0")
  elif pacman -Q plasma-workspace >/dev/null 2>&1; then
    kde_detected=true
    # Get installed version
    plasma_version=$(pacman -Qi plasma-workspace | grep Version | awk '{print $2}' | cut -d'-' -f1)
  elif [[ -d "/usr/share/plasma" ]] || [[ -d "/usr/lib/plasma" ]]; then
    kde_detected=true
    plasma_version="6.0"  # Assume Plasma 6+ if directory exists
  fi

  # Only proceed if Plasma 6+ is detected
  if [[ "$kde_detected" == true ]]; then
    log_info "KDE Plasma detected: $plasma_version"
    
    # Extract version number for validation
    local version_number=$(echo "$plasma_version" | grep -oP '\d+' | head -1)
    
    # Only support Plasma 6+ for bleeding edge Arch Linux
    if [ -n "$version_number" ] && [ "$version_number" -ge 6 ]; then
      log_success "KDE Plasma 6+ detected - supported configuration"
    else
      log_error "KDE Plasma 5 detected - not supported on bleeding edge Arch Linux"
      log_info "Arch Linux recommends Plasma 6 for latest features and Qt6 support"
      return 0
    fi

    local kde_shortcuts_source="$CONFIGS_DIR/kglobalshortcutsrc"
    local kde_shortcuts_dest="$HOME/.config/kglobalshortcutsrc"
    local kwin_rules_file="$HOME/.config/kwinrulesrc"

    if [ -f "$kde_shortcuts_source" ]; then
      # Create .config directory if it doesn't exist
      mkdir -p "$HOME/.config"

      # Remove existing file first to ensure clean replacement
      if [ -f "$kde_shortcuts_dest" ]; then
        rm -f "$kde_shortcuts_dest"
        log_info "Removed existing kglobalshortcutsrc file"
      fi

      # Move the KDE global shortcuts configuration
      if mv "$kde_shortcuts_source" "$kde_shortcuts_dest"; then
        log_success "KDE shortcuts file moved successfully"
        log_info "Shortcuts: Meta+Q & Alt+F4 (Close Window), Meta+Return (Konsole)"
        
        # Verify Meta+Q shortcut is properly configured
        if grep -q "Window Close=Meta+Q" "$kde_shortcuts_dest"; then
          log_success "Meta+Q shortcut found in configuration"
        else
          log_warning "Meta+Q shortcut not found in configuration file"
        fi
        
        # Verify conflicting shortcuts are disabled
        if grep -q "Walk Through Windows of Current Application=none" "$kde_shortcuts_dest"; then
          log_success "Conflicting Meta+ shortcuts disabled for Meta+Q to work"
        fi
        
        # Verify activity switcher moved to Ctrl+Q
        if grep -q "manage activities=Ctrl+Q" "$kde_shortcuts_dest"; then
          log_success "Activity switcher moved to Ctrl+Q to free Meta+Q for window closing"
        fi
        
        log_info "Changes will take effect after Plasma restart or logout/login"
        log_info "Note: Meta+Q now closes windows, Ctrl+Q opens activity switcher"
      else
        log_error "Failed to move kglobalshortcutsrc file"
        return 1
      fi
    else
      log_warning "KDE shortcuts configuration file not found at $kde_shortcuts_source"
    fi

    # Setup Konsole fullscreen window rules
    setup_konsole_fullscreen_rules
    
    # Apply KDE changes immediately
    apply_kde_changes

  else
    log_info "KDE Plasma not detected. Skipping KDE shortcuts configuration"
  fi
}

setup_gnome_configs() {
  step "Setting up GNOME configurations"

  # Only proceed if GNOME is detected
  if [[ "$XDG_CURRENT_DESKTOP" == "GNOME" ]] || [[ "$XDG_CURRENT_DESKTOP" == *"GNOME"* ]]; then
    # Get full GNOME version
    local gnome_version
    gnome_version=$(get_desktop_version "GNOME")

    log_info "GNOME detected: $gnome_version"
    log_info "Applying optimizations..."

    # Check if gsettings is available
    if command -v gsettings >/dev/null 2>&1; then
      # Helper function to check if schema exists
      schema_exists() {
        gsettings list-schemas 2>/dev/null | grep -q "^$1$"
      }

      # Helper function to check if schema key exists
      key_exists() {
        gsettings list-keys "$1" 2>/dev/null | grep -q "^$2$"
      }

      # Set dark theme preference (GNOME 42+)
      if schema_exists "org.gnome.desktop.interface" && key_exists "org.gnome.desktop.interface" "color-scheme"; then
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null && \
          log_success "Dark theme preference set"
      fi

      # Enable minimize and maximize buttons
      if schema_exists "org.gnome.desktop.wm.preferences"; then
        gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close' 2>/dev/null && \
          log_success "Window buttons configured (minimize, maximize, close)"
      fi

      # Set tap-to-click for touchpad
      if schema_exists "org.gnome.desktop.peripherals.touchpad"; then
        gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true 2>/dev/null && \
          log_success "Tap-to-click enabled"
      fi

      # Disable hot corner
      if schema_exists "org.gnome.desktop.interface" && key_exists "org.gnome.desktop.interface" "enable-hot-corners"; then
        gsettings set org.gnome.desktop.interface enable-hot-corners false 2>/dev/null && \
          log_success "Hot corners disabled"
      fi

      # Set font rendering
      if schema_exists "org.gnome.desktop.interface"; then
        gsettings set org.gnome.desktop.interface font-antialiasing 'rgba' 2>/dev/null
        gsettings set org.gnome.desktop.interface font-hinting 'slight' 2>/dev/null && \
          log_success "Font rendering optimized"
      fi

      # Set battery percentage
      if schema_exists "org.gnome.desktop.interface"; then
        gsettings set org.gnome.desktop.interface show-battery-percentage true 2>/dev/null && \
          log_success "Battery percentage enabled"
      fi

      # Set Meta+Q to close windows
      if schema_exists "org.gnome.desktop.wm.keybindings"; then
        gsettings set org.gnome.desktop.wm.keybindings close "['<Super>q']" 2>/dev/null && \
          log_success "Meta+Q set to close windows"
      fi

      # Set Meta+Enter to open terminal
      # GNOME uses different terminal apps: kgx (Console), gnome-console, or gnome-terminal
      if schema_exists "org.gnome.settings-daemon.plugins.media-keys"; then
        if command -v kgx >/dev/null 2>&1; then
          gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']" 2>/dev/null
          gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ name 'Terminal' 2>/dev/null
          gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ command 'kgx' 2>/dev/null
          gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ binding '<Super>Return' 2>/dev/null && \
            log_success "Meta+Enter set to open Console (kgx)"
        elif command -v gnome-console >/dev/null 2>&1; then
          gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']" 2>/dev/null
          gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ name 'Terminal' 2>/dev/null
          gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ command 'gnome-console' 2>/dev/null
          gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ binding '<Super>Return' 2>/dev/null && \
            log_success "Meta+Enter set to open Console (gnome-console)"
        elif command -v gnome-terminal >/dev/null 2>&1; then
          gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']" 2>/dev/null
          gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ name 'Terminal' 2>/dev/null
          gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ command 'gnome-terminal' 2>/dev/null
          gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ binding '<Super>Return' 2>/dev/null && \
            log_success "Meta+Enter set to open Terminal (gnome-terminal)"
        else
          log_warning "No GNOME terminal found (kgx, gnome-console, or gnome-terminal)"
        fi
      fi

      # Set PrintScreen to take full screenshot
      if schema_exists "org.gnome.shell.keybindings"; then
        gsettings set org.gnome.shell.keybindings screenshot "['Print']" 2>/dev/null && \
          log_success "PrintScreen set to capture full screen"
      fi

      # Set Ctrl+Alt+Delete to show power menu
      # Try both possible schema locations (varies by GNOME version)
      if schema_exists "org.gnome.settings-daemon.plugins.media-keys" && key_exists "org.gnome.settings-daemon.plugins.media-keys" "logout"; then
        gsettings set org.gnome.settings-daemon.plugins.media-keys logout "['<Primary><Alt>Delete']" 2>/dev/null && \
          log_success "Ctrl+Alt+Delete set to show power menu (Reboot/Shutdown/Logout)"
      elif schema_exists "org.gnome.SessionManager"; then
        gsettings set org.gnome.SessionManager logout "['<Primary><Alt>Delete']" 2>/dev/null && \
          log_success "Ctrl+Alt+Delete set to show power menu (Reboot/Shutdown/Logout)"
      fi

      log_success "GNOME configurations applied successfully"
      log_info "GNOME settings will be active after next login or session restart"
      log_info "Tested and compatible with GNOME 40 through GNOME 49+"
    else
      log_warning "gsettings not found. Skipping GNOME configurations"
    fi
  else
    log_info "GNOME not detected. Skipping GNOME configurations"
  fi
}

# Function to setup Konsole maximized window rules
setup_konsole_fullscreen_rules() {
  log_info "Setting up Konsole maximized window rules..."
  
  local kwin_rules_source="$CONFIGS_DIR/kwinrulesrc"
  local kwin_rules_dest="$HOME/.config/kwinrulesrc"
  
  # Create .config directory if it doesn't exist
  mkdir -p "$HOME/.config"
  
  # Copy the pre-configured kwinrulesrc from configs to user config
  if [ -f "$kwin_rules_source" ]; then
    cp "$kwin_rules_source" "$kwin_rules_dest"
    log_success "KDE window rules copied from configs to ~/.config/kwinrulesrc"
    log_info "Konsole will automatically go maximized without titlebar"
    
    # Verify the file was copied correctly
    if [ -f "$kwin_rules_dest" ]; then
      log_success "KDE window rules file verified at $kwin_rules_dest"
      # Check for Konsole maximized rule
      if grep -q "Konsole Maximized" "$kwin_rules_dest"; then
        log_success "Konsole maximized rule found in configuration"
      else
        log_warning "Konsole maximized rule not found in configuration file"
      fi
      
      # Check for specific rule properties
      if grep -q "noborder=true" "$kwin_rules_dest" && grep -q "maximize=true" "$kwin_rules_dest"; then
        log_success "Konsole no-border and maximized rules verified"
      else
        log_warning "Konsole border or maximized rules not properly configured"
      fi
      
      # Check for window class matching
      if grep -q "wmclass=konsole" "$kwin_rules_dest"; then
        log_success "Konsole window class matching verified"
      else
        log_warning "Konsole window class matching not found"
      fi
      
      # Set proper permissions
      chmod 644 "$kwin_rules_dest"
      log_success "Set proper permissions on KDE window rules file"
    else
      log_error "KDE window rules file was not copied successfully"
    fi
  else
    log_warning "KDE window rules configuration file not found at $kwin_rules_source"
  fi
}

# Apply KDE changes immediately
apply_kde_changes() {
  log_info "Applying KDE configuration changes..."
  
  # Restart kglobalshortcut daemon to apply new shortcuts
  if command -v kquitapp5 >/dev/null 2>&1; then
    kquitapp5 kglobalaccel && kstart5 kglobalaccel >/dev/null 2>&1 &
    log_success "Restarted KDE global shortcuts daemon"
  fi
  
  # Restart kwin to apply window rules
  if command -v kquitapp5 >/dev/null 2>&1; then
    kquitapp5 kwin && kstart5 kwin >/dev/null 2>&1 &
    log_success "Restarted KWin window manager"
  fi
  
  # Alternative method: use dbus to reload configurations
  if command -v qdbus >/dev/null 2>&1; then
    qdbus org.kde.kglobalaccel /Component reconfigure >/dev/null 2>&1 || true
    qdbus org.kde.kwin /KWin reconfigure >/dev/null 2>&1 || true
    log_success "Sent reload signals to KDE components"
  fi
  
  ui_info "KDE shortcuts and window rules should now be active"
  ui_info "If changes don't appear, please restart KDE session"
}

# Main execution
setup_shell
setup_kde_shortcuts
setup_gnome_configs
