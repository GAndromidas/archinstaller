#!/bin/bash
set -uo pipefail

# ============================================================================
# UI Library - Enhanced Terminal Interface
# Provides unified UI functions using gum with fallback to traditional prompts
# ============================================================================

# Check if gum is available
supports_gum() {
    command -v gum &>/dev/null
}

# Unified menu function with arrow navigation
# Usage: ui_menu "Title" "Description" "Option1" "Option2" ...
ui_menu() {
    local title="$1"
    local description="${2:-}"
    shift 2
    local options=("$@")
    
    if supports_gum; then
        # Use gum for beautiful menu
        if [ -n "$description" ]; then
            gum style --foreground 226 --margin "1 0" "$description"
            echo ""
        fi
        
        gum choose --header="$title" "${options[@]}"
    else
        # Fallback to numbered menu
        echo ""
        echo -e "${CYAN}$title${RESET}"
        if [ -n "$description" ]; then
            echo -e "${DIM}$description${RESET}"
        fi
        echo ""
        
        local i=1
        for opt in "${options[@]}"; do
            echo -e "  ${CYAN}$i)${RESET} $opt"
            ((i++))
        done
        echo ""
        
        local selection
        while true; do
            read -r -p "$(echo -e "${CYAN}Select option [1-$((i-1))]: ${RESET}")" selection
            if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$((i-1))" ]; then
                echo "${options[$((selection-1))]}"
                return 0
            fi
            echo -e "${RED}Invalid selection. Try again.${RESET}"
        done
    fi
}

# Multi-select menu for custom packages
# Usage: ui_multiselect "Title" "Option1" "Option2" ...
ui_multiselect() {
    local title="$1"
    shift
    local options=("$@")
    
    if supports_gum; then
        gum choose --header="$title" --no-limit "${options[@]}"
    else
        # Fallback to space-separated selection
        echo ""
        echo -e "${CYAN}$title${RESET}"
        echo -e "${DIM}(Space to select, Enter to confirm)${RESET}"
        echo ""
        
        local i=1
        for opt in "${options[@]}"; do
            echo -e "  [ ] $i) $opt"
            ((i++))
        done
        echo ""
        
        local selection
        read -r -p "$(echo -e "${CYAN}Enter numbers (space-separated): ${RESET}")" selection
        
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$((i-1))" ]; then
                echo "${options[$((num-1))]}"
            fi
        done
    fi
}

# Confirmation dialog
# Usage: ui_confirm "Question?" "Optional description"
ui_confirm() {
    local question="$1"
    local description="${2:-}"
    
    if supports_gum; then
        if [ -n "$description" ]; then
            gum style --foreground 226 "$description"
        fi
        
        if gum confirm --default=true "$question"; then
            return 0
        else
            return 1
        fi
    else
        echo ""
        if [ -n "$description" ]; then
            echo -e "${YELLOW}${description}${RESET}"
        fi
        
        local response
        while true; do
            read -r -p "$(echo -e "${CYAN}${question} [Y/n]: ${RESET}")" response
            response=${response,,}
            case "$response" in
                ""|y|yes) return 0 ;;
                n|no) return 1 ;;
                *) echo -e "\n${RED}Please answer Y (yes) or N (no).${RESET}\n" ;;
            esac
        done
    fi
}

# Progress spinner for long operations
# Usage: ui_spinner "Message" command arg1 arg2 ...
ui_spinner() {
    local message="$1"
    shift
    local command=("$@")
    
    if supports_gum; then
        gum spin --spinner dot --title="$message" -- "${command[@]}"
    else
        echo -e "${CYAN}$message...${RESET}"
        "${command[@]}"
    fi
}

# Progress bar for batch operations
# Usage: ui_progress total current "message"
ui_progress() {
    local total="$1"
    local current="$2"
    local message="$3"
    
    if supports_gum; then
        local percent=$((current * 100 / total))
        gum format --template "progress" \
            --field "value:$percent" \
            --field "message:$message" \
            <<< "$message"
    else
        local bar_width=40
        local filled=$((current * bar_width / total))
        local empty=$((bar_width - filled))
        printf "\r${CYAN}%s${RESET} [%s%s] %d/%d" \
            "$message" \
            "$(printf '#%.0s' $(seq 1 $filled))" \
            "$(printf ' %.0s' $(seq 1 $empty))" \
            "$current" "$total"
    fi
}

# Styled header
# Usage: ui_header "Title"
ui_header() {
    local title="$1"
    if supports_gum; then
        gum style --border normal --margin "1 2" --padding "1 2" --align center "$title"
    else
        echo ""
        echo -e "${CYAN}### ${title} ###${RESET}"
        echo ""
    fi
}

# Info message
# Usage: ui_info "Message"
ui_info() {
    local message="$1"
    if supports_gum; then
        gum style --foreground 36 "$message"
    else
        echo -e "${CYAN}$message${RESET}"
    fi
}

# Success message
# Usage: ui_success "Message"
ui_success() {
    local message="$1"
    if supports_gum; then
        gum style --foreground 46 "✓ $message"
    else
        echo -e "${GREEN}✓ $message${RESET}"
    fi
}

# Warning message
# Usage: ui_warn "Message"
ui_warn() {
    local message="$1"
    if supports_gum; then
        gum style --foreground 226 "⚠ $message"
    else
        echo -e "${YELLOW}⚠ $message${RESET}"
    fi
}

# Error message
# Usage: ui_error "Message"
ui_error() {
    local message="$1"
    if supports_gum; then
        gum style --foreground 196 "✗ $message"
    else
        echo -e "${RED}✗ $message${RESET}"
    fi
}

# Input prompt
# Usage: ui_input "Prompt" "default_value"
ui_input() {
    local prompt="$1"
    local default="${2:-}"
    
    if supports_gum; then
        gum input --prompt="$prompt" --value="$default"
    else
        local response
        read -r -p "$(echo -e "${CYAN}${prompt}${RESET}")" response
        echo "${response:-$default}"
    fi
}

# Password input
# Usage: ui_password "Prompt"
ui_password() {
    local prompt="$1"
    
    if supports_gum; then
        gum input --password --prompt="$prompt"
    else
        local response
        read -r -s -p "$(echo -e "${CYAN}${prompt}${RESET}")" response
        echo ""
        echo "$response"
    fi
}

# Simple banner
# Usage: simple_banner "Title"
simple_banner() {
    local title="$1"
    echo ""
    if supports_gum; then
        gum style --border double --align center --padding "1 2" "$title"
    else
        echo -e "${CYAN}========================================${RESET}"
        echo -e "${CYAN}  ${title}${RESET}"
        echo -e "${CYAN}========================================${RESET}"
    fi
    echo ""
}

# Step indicator
# Usage: step "Step description"
step() {
    local message="$1"
    if supports_gum; then
        gum style --foreground 212 "▶ $message"
    else
        echo -e "${PURPLE}▶ $message${RESET}"
    fi
}
