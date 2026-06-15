#!/bin/bash
set -uo pipefail

# ============================================================================
# Dashboard Module — Professional wizard-style installation display
# Uses pure bash + tput for a persistent full-screen frame with in-place
# step updates. No external dependencies (gum optional elsewhere).
# ============================================================================

DASHBOARD_START_TIME=0
DASHBOARD_STEP_TIMES=()
DASHBOARD_STEP_NAMES=()
DASHBOARD_STEP_STATUSES=()
DASHBOARD_STEP_ROWS=()
DASHBOARD_INNER_W=60
DASHBOARD_CURRENT_STEP=0
DASHBOARD_STEP_START=0
DASHBOARD_FRAME_END=0

dashboard_init() {
    clear
    DASHBOARD_START_TIME=$(date +%s)
    DASHBOARD_STEP_TIMES=()
    DASHBOARD_STEP_NAMES=()
    DASHBOARD_STEP_STATUSES=()
    DASHBOARD_STEP_ROWS=()

    local total=${TOTAL_STEPS:-11}
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    local w=$((cols - 4))
    (( w < 50 )) && w=50
    (( w > 80 )) && w=80
    DASHBOARD_INNER_W=$w

    local row=0

    # Top border
    echo -e "${THEME_BORDER}  ┌$(printf '─%.0s' $(seq 1 $w))┐${RESET}"
    row=1

    # Title line
    local title="● Arch Installer"
    local step_info="Step 1/${total}"
    local title_pad=$((w - ${#title} - ${#step_info} - 2))
    (( title_pad < 1 )) && title_pad=1
    printf "${THEME_BORDER}  │${RESET} ${THEME_HEADER}%s${RESET}%*s ${THEME_MUTED}%s${RESET} ${THEME_BORDER}│${RESET}\n" \
        "$title" $title_pad "" "$step_info"
    row=2

    # Separator
    echo -e "${THEME_BORDER}  ├$(printf '─%.0s' $(seq 1 $w))┤${RESET}"
    local progress_row=3

    # Progress bar line (cleared, will be updated by dashboard_step)
    echo -e "${THEME_BORDER}  │${RESET}$(printf '%*s' $w '')${THEME_BORDER}│${RESET}"
    row=4

    # Separator
    echo -e "${THEME_BORDER}  ├$(printf '─%.0s' $(seq 1 $w))┤${RESET}"
    row=5

    # Step lines
    for ((i = 1; i <= total; i++)); do
        DASHBOARD_STEP_ROWS[$i]=$row
        printf "${THEME_BORDER}  │${RESET}  %2d  ○ %-*s  ${THEME_BORDER}│${RESET}\n" \
            "$i" $((w - 10)) "Pending"
        ((row++))
    done

    # Bottom separator
    local bottom_sep=$row
    echo -e "${THEME_BORDER}  ├$(printf '─%.0s' $(seq 1 $w))┤${RESET}"
    ((row++))

    # Info line
    local log_info="Log: $INSTALL_LOG"
    local cancel_info="Ctrl+C to cancel"
    local info_pad=$((w - ${#log_info} - ${#cancel_info} - 2))
    (( info_pad < 1 )) && info_pad=1
    printf "${THEME_BORDER}  │${RESET} ${THEME_MUTED}%s${RESET}%*s ${THEME_MUTED}%s${RESET} ${THEME_BORDER}│${RESET}\n" \
        "$log_info" $info_pad "" "$cancel_info"
    ((row++))

    # Bottom border
    echo -e "${THEME_BORDER}  └$(printf '─%.0s' $(seq 1 $w))┘${RESET}"
    DASHBOARD_FRAME_END=$row

    # Move cursor below the frame for any auxiliary output
    tput cup $((DASHBOARD_FRAME_END + 1)) 0
}

dashboard_step() {
    local name=$1 num=$2
    local total=${TOTAL_STEPS:-11}
    local w=$DASHBOARD_INNER_W

    DASHBOARD_CURRENT_STEP=$num
    DASHBOARD_STEP_NAMES[$num]="$name"
    DASHBOARD_STEP_TIMES[$num]=0
    DASHBOARD_STEP_STATUSES[$num]="running"

    local pct=$(( (num - 1) * 100 / total ))
    local bar_width=$w
    local filled=$(( pct * bar_width / 100 ))
    (( filled < 0 )) && filled=0
    (( filled > bar_width )) && filled=$bar_width

    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=filled; i<bar_width; i++)); do bar+="░"; done

    # Truncate name if too long for progress bar line
    local disp_name="$name"
    local max_name_len=$((w - 8))
    (( ${#disp_name} > max_name_len )) && disp_name="${disp_name:0:$((max_name_len-1))}…"

    # Update title with current step number
    local title="● Arch Installer"
    local step_info="Step ${num}/${total}"
    local title_pad=$((w - ${#title} - ${#step_info} - 2))
    (( title_pad < 1 )) && title_pad=1
    tput cup 1 0
    tput el
    printf "${THEME_BORDER}  │${RESET} ${THEME_HEADER}%s${RESET}%*s ${THEME_MUTED}%s${RESET} ${THEME_BORDER}│${RESET}" \
        "$title" $title_pad "" "$step_info"

    # Update progress bar line
    tput cup 3 0
    tput el
    printf "${THEME_BORDER}  │${RESET} ${THEME_SUCCESS}%s${RESET} ${THEME_TEXT}%s${RESET}%*s${THEME_BORDER}│${RESET}" \
        "$bar" "$disp_name" $((w - bar_width - ${#disp_name} - 1)) ""

    # Update current step line
    local step_row="${DASHBOARD_STEP_ROWS[$num]}"
    tput cup $step_row 0
    tput el
    printf "${THEME_BORDER}  │${RESET}  %2d  ⏳ %-*s  ${THEME_BORDER}│${RESET}" \
        "$num" $((w - 10)) "Running..."

    # Move cursor below the frame
    tput cup $((DASHBOARD_FRAME_END + 1)) 0

    DASHBOARD_STEP_START=$(date +%s)
}

dashboard_run() {
    local script_path=$1

    source "$script_path" >> "$INSTALL_LOG" 2>&1
    local ret=$?
    return $ret
}

dashboard_ok() {
    local elapsed=0
    [ "$DASHBOARD_STEP_START" -gt 0 ] && elapsed=$(($(date +%s) - DASHBOARD_STEP_START))
    local num=$DASHBOARD_CURRENT_STEP
    local w=$DASHBOARD_INNER_W
    DASHBOARD_STEP_STATUSES[$num]="ok"
    DASHBOARD_STEP_TIMES[$num]=$elapsed

    local time_str="$(format_time $elapsed)"
    local step_row="${DASHBOARD_STEP_ROWS[$num]}"
    local name="${DASHBOARD_STEP_NAMES[$num]}"

    tput cup $step_row 0
    tput el
    printf "${THEME_BORDER}  │${RESET}  %2d  ${THEME_SUCCESS}✓${RESET} %-*s ${THEME_MUTED}%6s${RESET}  ${THEME_BORDER}│${RESET}" \
        "$num" $((w - 21)) "$name" "$time_str"

    tput cup $((DASHBOARD_FRAME_END + 1)) 0
}

dashboard_fail() {
    local elapsed=0
    [ "$DASHBOARD_STEP_START" -gt 0 ] && elapsed=$(($(date +%s) - DASHBOARD_STEP_START))
    local num=$DASHBOARD_CURRENT_STEP
    local w=$DASHBOARD_INNER_W
    DASHBOARD_STEP_STATUSES[$num]="fail"
    DASHBOARD_STEP_TIMES[$num]=$elapsed

    local time_str="$(format_time $elapsed)"
    local step_row="${DASHBOARD_STEP_ROWS[$num]}"
    local name="${DASHBOARD_STEP_NAMES[$num]}"

    tput cup $step_row 0
    tput el
    printf "${THEME_BORDER}  │${RESET}  %2d  ${THEME_ERROR}✗${RESET} %-*s ${THEME_MUTED}%6s${RESET}  ${THEME_BORDER}│${RESET}" \
        "$num" $((w - 21)) "$name" "$time_str"

    tput cup $((DASHBOARD_FRAME_END + 1)) 0
}

dashboard_skip() {
    local msg="${1:-Already completed}"
    local num=$DASHBOARD_CURRENT_STEP
    local w=$DASHBOARD_INNER_W
    DASHBOARD_STEP_STATUSES[$num]="skip"
    DASHBOARD_STEP_TIMES[$num]=0

    local step_row="${DASHBOARD_STEP_ROWS[$num]}"

    # Truncate message to fit
    local disp_msg="$msg"
    local max_msg=$((w - 10))
    (( ${#disp_msg} > max_msg )) && disp_msg="${disp_msg:0:$((max_msg-1))}…"

    tput cup $step_row 0
    tput el
    printf "${THEME_BORDER}  │${RESET}  %2d  ${THEME_MUTED}◇${RESET} %-*s  ${THEME_BORDER}│${RESET}" \
        "$num" $((w - 10)) "$disp_msg"

    tput cup $((DASHBOARD_FRAME_END + 1)) 0
}

dashboard_finish() {
    clear

    local total=${TOTAL_STEPS:-11}
    local success=0 fail=0 skip=0

    for ((i = 1; i <= total; i++)); do
        [[ -v DASHBOARD_STEP_STATUSES[$i] ]] || continue
        case "${DASHBOARD_STEP_STATUSES[$i]}" in
            ok)   ((success++)) ;;
            fail) ((fail++)) ;;
            skip) ((skip++)) ;;
        esac
    done

    local wall_time=$(( $(date +%s) - DASHBOARD_START_TIME ))
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    local w=$((cols - 4))
    (( w < 50 )) && w=50
    (( w > 80 )) && w=80

    local title
    if [ "$fail" -gt 0 ]; then
        title="Installation Completed — ${fail} step(s) failed"
    else
        title="Installation Complete"
    fi

    # Title panel
    echo -e "${THEME_BORDER}  ╔$(printf '═%.0s' $(seq 1 $w))╗${RESET}"
    local title_pad=$(( (w - ${#title}) / 2 ))
    (( title_pad < 1 )) && title_pad=1
    printf "${THEME_BORDER}  ║${RESET}%*s${THEME_HEADER}%s${RESET}%*s${THEME_BORDER}║${RESET}\n" \
        $title_pad '' "$title" $((w - title_pad - ${#title})) ''
    echo -e "${THEME_BORDER}  ╚$(printf '═%.0s' $(seq 1 $w))╝${RESET}"
    echo ""

    # Step results
    for ((i = 1; i <= total; i++)); do
        [[ -v DASHBOARD_STEP_STATUSES[$i] ]] || continue
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
        local time_str
        if [ "$st" = "skip" ]; then
            time_str="  --  "
        else
            time_str="$(format_time $tm)"
            time_str=$(printf "%6s" "$time_str")
        fi
        printf "${color}  %s  Step %2d: %-28s${THEME_MUTED} %s${RESET}\n" \
            "$icon" "$i" "$name" "$time_str"
    done

    echo ""
    echo -e "${THEME_MUTED}  $(printf '─%.0s' $(seq 1 $w))${RESET}"
    echo ""
    echo -e "${THEME_TEXT}    ${success} completed, ${fail} failed, ${skip} skipped  |  Total: $(format_time $wall_time)${RESET}"
    echo ""

    log_to_file "Installation finished. $success completed, $fail failed, $skip skipped in $(format_time $wall_time)"
}
