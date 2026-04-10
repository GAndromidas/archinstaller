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

  # Only proceed if KDE Plasma is detected
  if [[ "$XDG_CURRENT_DESKTOP" == "KDE" ]]; then
    # Get full Plasma version
    local plasma_version
    plasma_version=$(get_desktop_version "KDE")

    log_info "KDE Plasma detected: $plasma_version"
    
    # Extract version number for validation
    local version_number=$(echo "$plasma_version" | grep -oP '\d+' | head -1)
    
    # Only support Plasma 6+ for bleeding edge Arch Linux
    if [ -n "$version_number" ] && [ "$version_number" -ge 6 ]; then
      log_success "KDE Plasma 6+ detected - supported configuration"
      
      # Install PyQt6 silently for KDE automation if not already installed
      if ! pacman -Qi python-pyqt6 &>/dev/null; then
        log_info "Installing python-pyqt6 for KDE automation..."
        if sudo pacman -S --noconfirm --needed python-pyqt6 >/dev/null 2>&1; then
          log_success "python-pyqt6 installed successfully"
        else
          log_warning "Failed to install python-pyqt6, some KDE features may not work"
        fi
      fi
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

      # Copy the KDE global shortcuts configuration, replacing the old one
      cp "$kde_shortcuts_source" "$kde_shortcuts_dest"
      log_success "KDE global shortcuts configuration copied successfully"
      log_info "KDE shortcuts will be active after next login or KDE restart"
      log_info "Custom shortcuts: Meta+Q (Close Window), Meta+Return (Konsole)"
    else
      log_warning "KDE shortcuts configuration file not found at $kde_shortcuts_source"
    fi

    # Setup Konsole fullscreen window rules
    setup_konsole_fullscreen_rules

    # Setup Konsole fullscreen launcher
    setup_konsole_launcher

    # Reload KDE configuration
    reload_kde_config

    # Cleanup temporary dependencies
    cleanup_kde_dependencies

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

# Function to setup Konsole fullscreen window rules
setup_konsole_fullscreen_rules() {
  log_info "Setting up Konsole fullscreen window rules..."
  
  local kwin_rules_file="$HOME/.config/kwinrulesrc"
  
  # Backup existing rules if they exist
  if [ -f "$kwin_rules_file" ]; then
    cp "$kwin_rules_file" "${kwin_rules_file}.backup.$(date +%Y%m%d_%H%M%S)"
  fi
  
  # Create or update kwinrulesrc with Konsole fullscreen rule
  if [ ! -f "$kwin_rules_file" ]; then
    # Create new file with Konsole rule
    cat > "$kwin_rules_file" << 'EOF'
[General]
count=1
rules=1

[1]
Description=Konsole Fullscreen
Description=
clientMachine=
clientMachineMatch=true
types=1
types=0
title=konsole
titlematch=0
windowclass=konsole
windowclassmatch=0
windowrole=
windowrolematch=0
clientmachine=
clientmachinematch=0
resourceclass=konsole
resourceclassmatch=0
resource=
resourcematch=0
position=0,0
positionrule=0
size=0,0
sizerule=0
minsize=0,0
minsizerule=0
maxsize=0,0
maxsizerule=0
opacity=100
opacityrule=0
opacityactive=100
opacityactiverule=0
fullscreen=false
fullscreenrule=2
minimize=false
minimizerule=0
shade=false
shaderule=0
skiptaskbar=false
skiptaskbarrule=0
skippager=false
skippagerrule=0
above=false
aboverule=0
below=false
belowrule=0
noborder=false
noborderrule=0
screenclass=0
screenrule=0
fullscreen=true
fullscreenrule=1
desktop=0
desktoprule=0
type=0
typerule=0
maxvert=true
maxvertrule=0
maxhoriz=true
maxhorizrule=0
layer=0
layerrule=0
placement=0
placementrule=0
shortcut=
shortcutrule=0
EOF
  else
    # Add Konsole rule to existing file if not already present
    if ! grep -q "Description=Konsole Fullscreen" "$kwin_rules_file"; then
      local rule_count=$(grep "^\[General\]" -A 5 "$kwin_rules_file" | grep "^count=" | cut -d'=' -f2)
      local new_rule_num=$((rule_count + 1))
      
      # Update count
      sed -i "s/^count=.*/count=$new_rule_num/" "$kwin_rules_file"
      sed -i "s/^rules=.*/rules=$new_rule_num/" "$kwin_rules_file"
      
      # Add new rule section
      cat >> "$kwin_rules_file" << EOF

[$new_rule_num]
Description=Konsole Fullscreen
Description=
clientMachine=
clientMachineMatch=true
types=1
types=0
title=konsole
titlematch=0
windowclass=konsole
windowclassmatch=0
windowrole=
windowrolematch=0
clientmachine=
clientmachinematch=0
resourceclass=konsole
resourceclassmatch=0
resource=
resourcematch=0
position=0,0
positionrule=0
size=0,0
sizerule=0
minsize=0,0
minsizerule=0
maxsize=0,0
maxsizerule=0
opacity=100
opacityrule=0
opacityactive=100
opacityactiverule=0
fullscreen=false
fullscreenrule=2
minimize=false
minimizerule=0
shade=false
shaderule=0
skiptaskbar=false
skiptaskbarrule=0
skippager=false
skippagerrule=0
above=false
aboverule=0
below=false
belowrule=0
noborder=false
noborderrule=0
screenclass=0
screenrule=0
fullscreen=true
fullscreenrule=1
desktop=0
desktoprule=0
type=0
typerule=0
maxvert=true
maxvertrule=0
maxhoriz=true
maxhorizrule=0
layer=0
layerrule=0
placement=0
placementrule=0
shortcut=
shortcutrule=0
EOF
    fi
  fi
  
  log_success "Konsole fullscreen window rules configured"
}

# Function to setup Konsole fullscreen launcher
setup_konsole_launcher() {
  log_info "Setting up Konsole fullscreen launcher..."
  
  # Install xdotool if not present
  if ! pacman -Q xdotool &>/dev/null; then
    log_info "Installing xdotool for Konsole launcher..."
    sudo pacman -S --noconfirm xdotool || {
      log_warning "Failed to install xdotool, Konsole launcher may not work properly"
    }
  fi
  
  # Create launcher script
  local launcher_dir="$HOME/.local/bin"
  mkdir -p "$launcher_dir"
  
  local launcher_script="$launcher_dir/konsole-fullscreen"
  
  cat > "$launcher_script" << 'EOF'
#!/bin/bash
# Konsole Fullscreen Launcher

# Check if Konsole is already running
if pgrep -f "konsole" > /dev/null; then
  # If running, bring to front and toggle fullscreen
  qdbus org.kde.konsole /MainApplication org.kde.MainApplication.raise
  qdbus org.kde.konsole /MainApplication org.kde.MainApplication.activate
  sleep 0.5
  # Send F11 to toggle fullscreen
  xdotool key F11
else
  # Start new Konsole instance
  konsole &
  sleep 1
  # Force fullscreen
  xdotool key F11
fi
EOF
  
  chmod +x "$launcher_script"
  log_success "Created Konsole fullscreen launcher at $launcher_script"
}

# Function to cleanup temporary PyQt6 after KDE configuration
cleanup_kde_dependencies() {
  # Check if python-pyqt6 was installed as helper utility and remove it
  if pacman -Q python-pyqt6 &>/dev/null; then
    log_info "Cleaning up temporary python-pyqt6 (no longer needed after KDE configuration)"
    sudo pacman -Rns --noconfirm python-pyqt6 || {
      log_warning "Failed to remove python-pyqt6, will keep installed"
    }
  fi
}

# Function to reload KDE configuration
reload_kde_config() {
  log_info "Reloading KDE configuration..."
  
  # Check if qdbus is available
  if ! command -v qdbus >/dev/null 2>&1; then
    log_info "qdbus command not found, KDE configuration will apply on next login"
    log_info "This is normal - qdbus is part of qt6-tools and may not be installed"
    return 0
  fi
  
  # Reload KWin rules
  if pgrep -x "kwin_x11" > /dev/null || pgrep -x "kwin_wayland" > /dev/null; then
    if qdbus org.kde.KWin /KWin reconfigure >/dev/null 2>&1; then
      log_success "KWin configuration reloaded"
    else
      log_info "KWin configuration will apply on next login"
    fi
  else
    log_info "KWin not running, will apply on next login"
  fi
  
  # Reload global shortcuts
  if qdbus org.kde.kglobalaccel /kglobalaccel reconfigure >/dev/null 2>&1; then
    log_success "Global shortcuts reloaded"
  else
    log_info "Global shortcuts will apply on next login"
  fi
}

# Main execution
setup_shell
setup_kde_shortcuts
setup_gnome_configs
