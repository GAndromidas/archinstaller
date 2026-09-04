#!/bin/bash
set -uo pipefail

# ============================================================================
# UI Library - Unified Terminal Interface with Blue/White Theme
# Provides unified UI functions using gum with fallback to traditional prompts
# ============================================================================

# Terminal helpers
__term_width() {
    tput cols 2>/dev/null || echo 80
}

__print_top_border() {
    local w=$(__term_width)
    echo -e "${THEME_BORDER}+$(printf '%*s' $((w - 2)) '' | tr ' ' '-')+${RESET}"
}

__print_bottom_border() {
    local w=$(__term_width)
    echo -e "${THEME_BORDER}+$(printf '%*s' $((w - 2)) '' | tr ' ' '-')+${RESET}"
}

__print_border_line() {
    local content="$1"
    local w=$(__term_width)
    local pad=$((w - ${#content} - 4))
    (( pad < 1 )) && pad=1
    echo -e "${THEME_BORDER}|${RESET} ${content}$(printf '%*s' $pad '') ${THEME_BORDER}|${RESET}"
}

__print_thick_top_border() {
    local w=$(__term_width)
    echo -e "${THEME_BORDER}#$(printf '%*s' $((w - 2)) '' | tr ' ' '=')#${RESET}"
}

__print_thick_bottom_border() {
    local w=$(__term_width)
    echo -e "${THEME_BORDER}#$(printf '%*s' $((w - 2)) '' | tr ' ' '=')#${RESET}"
}

__print_thick_border_line() {
    local content="$1"
    local w=$(__term_width)
    local pad=$((w - ${#content} - 4))
    (( pad < 1 )) && pad=1
    echo -e "${THEME_BORDER}#${RESET} ${content}$(printf '%*s' $pad '') ${THEME_BORDER}#${RESET}"
}

# Check if gum is available (cached after first call)
__supports_gum_cache=""
supports_gum() {
    if [ -z "$__supports_gum_cache" ]; then
        if command -v gum &>/dev/null; then
            __supports_gum_cache="true"
        else
            __supports_gum_cache="false"
        fi
    fi
    [ "$__supports_gum_cache" = "true" ]
}

# Unified menu function with arrow navigation
# Usage: ui_menu "Title" "Description" "Option1" "Option2" ...
ui_menu() {
    local title="$1"
    local description="${2:-}"
    shift 2
    local options=("$@")

    if supports_gum; then
        if [ -n "$description" ]; then
            gum style --foreground "$GUM_WARN" --margin "1 0" "$description"
            echo ""
        fi
        gum choose --header="$title" --cursor.foreground "$GUM_PRIMARY" --selected.foreground "$GUM_PRIMARY" "${options[@]}"
    else
        echo ""
        echo -e "${THEME_HEADER}$title${RESET}"
        if [ -n "$description" ]; then
            echo -e "${THEME_MUTED}$description${RESET}"
        fi
        echo ""
        local i=1
        for opt in "${options[@]}"; do
            echo -e "  ${THEME_SECONDARY}$i)${RESET} $opt"
            ((i++))
        done
        echo ""
        local selection
        while true; do
            read -r -p "$(echo -e "${THEME_SECONDARY}Select option [1-$((i-1))]: ${RESET}")" selection
            if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$((i-1))" ]; then
                echo "${options[$((selection-1))]}"
                return 0
            fi
            echo -e "${THEME_ERROR}Invalid selection. Try again.${RESET}"
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
        gum choose --header="$title" --no-limit --cursor.foreground "$GUM_PRIMARY" --selected.foreground "$GUM_PRIMARY" "${options[@]}"
    else
        echo ""
        echo -e "${THEME_HEADER}$title${RESET}"
        echo -e "${THEME_MUTED}(Enter numbers space-separated)${RESET}"
        echo ""
        local i=1
        for opt in "${options[@]}"; do
            echo -e "  [ ] $i) $opt"
            ((i++))
        done
        echo ""
        local selection
        read -r -p "$(echo -e "${THEME_SECONDARY}Enter numbers (space-separated): ${RESET}")" selection
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
        # Use subshell to temporarily restore stdio to terminal for gum display.
        # Must restore stdin too: dashboard_run redirects stdout/stderr to the
        # log, and without stdin on /dev/tty gum's key reader hangs until an
        # extra Enter flushes the buffer.
        (
            exec </dev/tty >/dev/tty 2>/dev/tty
            echo ""

            if [ -n "$description" ]; then
                gum style --foreground "$GUM_WARN" "$description"
            fi

            if gum confirm --default=true --prompt.foreground "$GUM_PRIMARY" --selected.background "$GUM_PRIMARY" "$question" </dev/tty; then
                exit 0
            else
                exit 1
            fi
            # ensure the cursor advances after gum's alt-screen leaves a stray newline
            echo "" >/dev/tty
        )
        local result=$?

        return $result
    else
        # Fallback when gum is unavailable. Interactive prompts are written to
        # /dev/tty so they remain visible even when called from a step subshell
        # whose stdout/stderr are redirected to the install log.
        local tty="/dev/tty"
        echo "" > "$tty"
        if [ -n "$description" ]; then
            echo -e "${THEME_WARN}${description}${RESET}" > "$tty"
        fi
        local response
        while true; do
            printf '%b' "${THEME_SECONDARY}${question} [Y/n]: ${RESET}" > "$tty"
            read -r response < "$tty" || response=""
            response=${response,,}
            case "$response" in
                ""|y|yes) return 0 ;;
                n|no) return 1 ;;
                *) printf '\n%b\n' "${THEME_ERROR}Please answer Y (yes) or N (no).${RESET}" > "$tty" ;;
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
        echo -e "${THEME_TEXT}$message...${RESET}"
        "${command[@]}"
    fi
}

# Styled header with bordered box
# Usage: ui_header "Title"
ui_header() {
    local title="$1"

    echo ""
    if supports_gum; then
        gum style --border normal --margin "1 2" --padding "1 2" --align center --foreground "$GUM_HEADER" "$title"
    else
        __print_top_border
        __print_border_line "${THEME_HEADER}${title}${RESET}"
        __print_bottom_border
    fi
    echo ""
}

# Info message (white)
# Usage: ui_info "Message"
ui_info() {
    local message="$1"
    if supports_gum; then
        gum style --foreground "$GUM_TEXT" "$message"
    else
        echo -e "${THEME_TEXT}$message${RESET}"
    fi
}

# Success message (green)
# Usage: ui_success "Message"
ui_success() {
    local message="$1"
    if supports_gum; then
        gum style --foreground "$GUM_SUCCESS" "✓ $message"
    else
        echo -e "${THEME_SUCCESS}✓ $message${RESET}"
    fi
}

# Warning message (yellow)
# Usage: ui_warn "Message"
ui_warn() {
    local message="$1"
    if supports_gum; then
        gum style --foreground "$GUM_WARN" "⚠ $message"
    else
        echo -e "${THEME_WARN}⚠ $message${RESET}"
    fi
}

# Error message (red)
# Usage: ui_error "Message"
ui_error() {
    local message="$1"
    if supports_gum; then
        gum style --foreground "$GUM_ERROR" "✗ $message"
    else
        echo -e "${THEME_ERROR}✗ $message${RESET}"
    fi
}

# Input prompt
# Usage: ui_input "Prompt" "default_value"
ui_input() {
    local prompt="$1"
    local default="${2:-}"

    if supports_gum; then
        gum input --prompt="$prompt" --prompt.foreground "$GUM_PRIMARY" --value="$default"
    else
        local response
        read -r -p "$(echo -e "${THEME_SECONDARY}${prompt}${RESET}")" response
        echo "${response:-$default}"
    fi
}

# Password input
# Usage: ui_password "Prompt"
ui_password() {
    local prompt="$1"

    if supports_gum; then
        gum input --password --prompt="$prompt" --prompt.foreground "$GUM_PRIMARY"
    else
        local response
        read -r -s -p "$(echo -e "${THEME_SECONDARY}${prompt}${RESET}")" response
        echo ""
        echo "$response"
    fi
}

# Simple banner with double-line box
# Usage: simple_banner "Title"
simple_banner() {
    local title="$1"

    echo ""
    if supports_gum; then
        gum style --border double --align center --padding "1 2" --foreground "$GUM_HEADER" "$title"
    else
        __print_thick_top_border
        __print_thick_border_line "${THEME_HEADER}  ${title}${RESET}"
        __print_thick_bottom_border
    fi
    echo ""
}

# Step indicator
# Usage: step "Step description"
if ! declare -f step >/dev/null 2>&1; then
step() {
    local message="$1"
    if supports_gum; then
        gum style --foreground "$GUM_PRIMARY" "▶ $message"
    else
        echo -e "${THEME_SECONDARY}▶ $message${RESET}"
    fi
}
fi
