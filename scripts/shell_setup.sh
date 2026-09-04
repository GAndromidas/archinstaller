#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$SCRIPT_DIR/../configs"
source "$SCRIPT_DIR/common.sh"

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
    if [ -f "$dst_starship" ]; then
      local bak="$dst_starship.backup.$(date +%Y%m%d_%H%M%S)"
      log_info "Backing up existing starship config to $bak"
      cp -a "$dst_starship" "$bak" || log_warning "Failed to back up $dst_starship"
    fi
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
    if [ -f "$dst_zshrc" ]; then
      local bak="$dst_zshrc.backup.$(date +%Y%m%d_%H%M%S)"
      log_info "Backing up existing .zshrc to $bak"
      cp -a "$dst_zshrc" "$bak" || log_warning "Failed to back up $dst_zshrc"
    fi
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
