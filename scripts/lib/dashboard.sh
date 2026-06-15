#!/bin/bash
set -uo pipefail

# ============================================================================
# Dashboard Module — Professional wizard-style installation display
# Provides a compact step header with progress bar, result tracking,
# and a clean final summary table.
# ============================================================================

DASHBOARD_START_TIME=0
DASHBOARD_STEP_TIMES=()
DASHBOARD_STEP_NAMES=()
DASHBOARD_STEP_STATUSES=()

__dashboard_progress_bar() {
    local current=$1 total=$2
    local width=30
    local pct=0
    [ "$total" -gt 0 ] && pct=$(( current * 100 / total ))
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    (( filled < 0 )) && filled=0
    (( filled > width )) && filled=$width
    (( empty < 0 )) && empty=0

    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="#"; done
    for ((i=0; i<empty; i++)); do bar+="."; done
    echo "$bar"
}

dashboard_init() {
    clear
    DASHBOARD_START_TIME=$(date +%s)
    DASHBOARD_STEP_TIMES=()
    DASHBOARD_STEP_NAMES=()
    DASHBOARD_STEP_STATUSES=()

    if supports_gum; then
        gum style --border double --padding "1 2" --align center \
            --foreground "$GUM_HEADER" --border-foreground "$GUM_BORDER" \
            "Arch Installer" "System Configuration Wizard"
    else
        local w
        w=$(tput cols 2>/dev/null || echo 80)
        echo -e "${THEME_BORDER}#$(printf '%*s' $((w - 2)) '' | tr ' ' '=')#${RESET}"
        echo -e "${THEME_BORDER}#${RESET}  ${THEME_HEADER}Arch Installer${RESET}"
        echo -e "${THEME_BORDER}#${RESET}  ${THEME_TEXT}System Configuration Wizard${RESET}"
        echo -e "${THEME_BORDER}#$(printf '%*s' $((w - 2)) '' | tr ' ' '=')#${RESET}"
    fi
    echo ""
}

dashboard_step() {
    local name=$1 num=$2
    local total=${TOTAL_STEPS:-11}
    local pct=$(( (num - 1) * 100 / total ))

    DASHBOARD_CURRENT_STEP=$num
    DASHBOARD_STEP_NAMES[$num]="$name"
    DASHBOARD_STEP_TIMES[$num]=0
    DASHBOARD_STEP_STATUSES[$num]="running"

    if supports_gum; then
        gum style --border normal --padding "0 1" \
            --foreground "$GUM_HEADER" --border-foreground "$GUM_BORDER" \
            "Step ${num}/${total}: ${name}"
    else
        local content="Step ${num}/${total}: ${name}"
        local border
        border=$(printf '%*s' $(( ${#content} + 2 )) '' | tr ' ' '=')
        echo -e "${THEME_BORDER}==${border}==${RESET}"
        echo -e "${THEME_BORDER}||${RESET} ${THEME_HEADER}${content}${RESET} ${THEME_BORDER}||${RESET}"
        echo -e "${THEME_BORDER}==${border}==${RESET}"
    fi

    if supports_gum; then
        local bar
        bar=$(__dashboard_progress_bar $((num - 1)) "$total")
        gum style --foreground "$GUM_TEXT" "  [${bar}] ${pct}%"
    else
        local bar
        bar=$(__dashboard_progress_bar $((num - 1)) "$total")
        echo -e "  ${THEME_TEXT}[${THEME_SUCCESS}$bar${THEME_TEXT}] ${pct}%${RESET}"
    fi

    DASHBOARD_STEP_START=$(date +%s)
    echo ""
}

dashboard_run() {
    local step_name=$1
    local script_path=$2

    if supports_gum; then
        gum spin --spinner dot --title "$step_name" -- bash -c "
            source '$script_path' >> '$INSTALL_LOG' 2>&1
        "
        return $?
    else
        source "$script_path" >> "$INSTALL_LOG" 2>&1
        return $?
    fi
}

dashboard_ok() {
    local num=${DASHBOARD_CURRENT_STEP:-${1:-0}}
    local elapsed=0
    if [ "$DASHBOARD_STEP_START" -gt 0 ]; then
        elapsed=$(($(date +%s) - DASHBOARD_STEP_START))
    fi
    DASHBOARD_STEP_STATUSES[$num]="ok"
    DASHBOARD_STEP_TIMES[$num]=$elapsed

    if supports_gum; then
        gum style --foreground "$GUM_SUCCESS" "  ✓ Completed  ($(format_time $elapsed))"
    else
        echo -e "  ${THEME_SUCCESS}✓ Completed${RESET}  ${THEME_MUTED}($(format_time $elapsed))${RESET}"
    fi
    echo ""
}

dashboard_fail() {
    local num=${DASHBOARD_CURRENT_STEP:-${1:-0}}
    local elapsed=0
    if [ "$DASHBOARD_STEP_START" -gt 0 ]; then
        elapsed=$(($(date +%s) - DASHBOARD_STEP_START))
    fi
    DASHBOARD_STEP_STATUSES[$num]="fail"
    DASHBOARD_STEP_TIMES[$num]=$elapsed

    if supports_gum; then
        gum style --foreground "$GUM_ERROR" "  ✗ Failed  ($(format_time $elapsed))"
    else
        echo -e "  ${THEME_ERROR}✗ Failed${RESET}  ${THEME_MUTED}($(format_time $elapsed))${RESET}"
    fi
    echo ""
}

dashboard_skip() {
    local msg="${1:-Already completed — skipped}"
    local num=${DASHBOARD_CURRENT_STEP}
    DASHBOARD_STEP_STATUSES[$num]="skip"
    DASHBOARD_STEP_TIMES[$num]=0

    if supports_gum; then
        gum style --foreground "$GUM_MUTED" "  ◇ $msg"
    else
        echo -e "  ${THEME_MUTED}◇ $msg${RESET}"
    fi
    echo ""
}

dashboard_finish() {
    local total=${TOTAL_STEPS:-11}
    local success=0 fail=0 skip=0

    for ((i = 1; i <= total; i++)); do
        case "${DASHBOARD_STEP_STATUSES[$i]}" in
            ok)   ((success++)) ;;
            fail) ((fail++)) ;;
            skip) ((skip++)) ;;
        esac
    done

    local total_time=0
    for t in "${DASHBOARD_STEP_TIMES[@]}"; do
        total_time=$((total_time + t))
    done
    local wall_time=$(( $(date +%s) - DASHBOARD_START_TIME ))

    clear
    echo ""

    local title
    if [ "$fail" -gt 0 ]; then
        title="Installation Completed — ${fail} step(s) failed"
    else
        title="Installation Complete"
    fi

    if supports_gum; then
        gum style --border thick --padding "1 2" --align center \
            --foreground "$GUM_HEADER" --border-foreground "$GUM_BORDER" \
            "$title"
        echo ""
        for ((i = 1; i <= total; i++)); do
            local name="${DASHBOARD_STEP_NAMES[$i]}"
            local st="${DASHBOARD_STEP_STATUSES[$i]}"
            local tm="${DASHBOARD_STEP_TIMES[$i]}"
            local icon col
            case "$st" in
                ok)   icon="✓"; col="$GUM_SUCCESS" ;;
                fail) icon="✗"; col="$GUM_ERROR" ;;
                skip) icon="◇"; col="$GUM_MUTED" ;;
                *)    icon="?"; col="$GUM_MUTED" ;;
            esac
            local line
            line=$(printf "%s  Step %2d: %-25s  (%s)" "$icon" "$i" "$name" "$(format_time $tm)")
            gum style --foreground "$col" "  ${line}"
        done
        echo ""
        gum style --foreground "$GUM_TEXT" "  ${success} completed, ${fail} failed, ${skip} skipped  |  Total: $(format_time $wall_time)"
    else
        local w
        w=$(tput cols 2>/dev/null || echo 80)
        local pad=$(( (w - ${#title} - 2) / 2 ))
        (( pad < 1 )) && pad=1
        echo -e "${THEME_BORDER}$(printf '%*s' "$w" '' | tr ' ' '=')${RESET}"
        printf "${THEME_BORDER}=${RESET}%*s${THEME_HEADER}%s${RESET}%*s${THEME_BORDER}=${RESET}\n" "$pad" '' "$title" "$pad" ''
        echo ""
        for ((i = 1; i <= total; i++)); do
            local name="${DASHBOARD_STEP_NAMES[$i]}"
            local st="${DASHBOARD_STEP_STATUSES[$i]}"
            local tm="${DASHBOARD_STEP_TIMES[$i]}"
            local icon color
            case "$st" in
                ok)   icon="✓"; color="$THEME_SUCCESS" ;;
                fail) icon="✗"; color="$THEME_ERROR" ;;
                skip) icon="◇"; color="$THEME_MUTED" ;;
                *)    icon="?"; color="$THEME_MUTED" ;;
            esac
            printf "${color}  %s  Step %2d: %-25s${THEME_MUTED} %s${RESET}\n" "$icon" "$i" "$name" "$(format_time $tm)"
        done
        echo ""
        echo -e "${THEME_TEXT}  ${success} completed, ${fail} failed, ${skip} skipped  |  Total: $(format_time $wall_time)${RESET}"
    fi

    echo ""
    log_to_file "Installation finished. $success completed, $fail failed, $skip skipped in $(format_time $wall_time)"
}
