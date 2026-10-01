#!/bin/bash
set -uo pipefail

# Dashboard: full-screen wizard frame via pure bash + tput, in-place step
# updates, no external deps.

# Local mono_now fallback (core.sh defines the canonical one; this keeps
# dashboard.sh functional if sourced standalone).
if ! declare -f mono_now >/dev/null 2>&1; then
mono_now() {
    local up
    up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "")
    if [[ "$up" =~ ^[0-9]+$ ]]; then
        echo "$up"
    else
        echo "$SECONDS"
    fi
}
fi

DASHBOARD_START_SEC=-1
DASHBOARD_STEP_TIMES=()
DASHBOARD_STEP_NAMES=()
DASHBOARD_STEP_STATUSES=()
DASHBOARD_STEP_ROWS=()
DASHBOARD_INNER_W=60
DASHBOARD_CURRENT_STEP=0
DASHBOARD_STEP_SEC=-1
DASHBOARD_FRAME_END=0
DASHBOARD_ROW_OFFSET=0
DASHBOARD_PLAIN=false

# Non-TTY (piped/CI) fallback: tput cup/el emits garbage when stdout is not
# a terminal. In plain mode every dashboard_* call degrades to simple
# step() logging so `./install.sh | tee` stays readable.
dashboard_is_tty() {
  [[ -t 1 ]] && [[ "${TERM:-dumb}" != dumb ]]
}

dashboard_init() {
    if dashboard_is_tty; then clear; fi
    if ! dashboard_is_tty; then
      DASHBOARD_PLAIN=true
      DASHBOARD_START_SEC=$(mono_now)
      echo "Arch Installer (plain output — non-interactive terminal)"
      return 0
    fi
    DASHBOARD_PLAIN=false
    DASHBOARD_STEP_SEC=-1
    DASHBOARD_STEP_TIMES=()
    DASHBOARD_STEP_NAMES=()
    DASHBOARD_STEP_STATUSES=()
    DASHBOARD_STEP_ROWS=()
    DASHBOARD_ROW_OFFSET=0

    local total=${TOTAL_STEPS:-10}
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    local w=$((cols - 4))
    (( w < 50 )) && w=50
    (( w > 120 )) && w=120
    DASHBOARD_INNER_W=$w

    local row=0

    # Top border
    echo -e "${THEME_BORDER}  ┌$(printf '─%.0s' $(seq 1 $w))┐${RESET}"
    row=1

    # Title line
    local mode_label="${INSTALL_MODE:-auto}"
    case "$mode_label" in default) mode_label="Standard" ;; minimal) mode_label="Minimal" ;; server) mode_label="Server" ;; esac
    local title="● Arch Installer · $mode_label"
    local step_info="Step 1/${total}"
    local title_pad=$((w - ${#title} - ${#step_info} - 3))
    (( title_pad < 1 )) && title_pad=1
    printf "${THEME_BORDER}  │${RESET} ${THEME_HEADER}%s${RESET}%*s ${THEME_MUTED}%s${RESET} ${THEME_BORDER}│${RESET}\n" \
        "$title" $title_pad "" "$step_info"
    row=2

    # Separator
    echo -e "${THEME_BORDER}  ├$(printf '─%.0s' $(seq 1 $w))┤${RESET}"

    # Progress bar line (cleared, will be updated by dashboard_step)
    echo -e "${THEME_BORDER}  │${RESET}$(printf '%*s' $w '')${THEME_BORDER}│${RESET}"
    row=4

    # Separator
    echo -e "${THEME_BORDER}  ├$(printf '─%.0s' $(seq 1 $w))┤${RESET}"
    row=5

    # Step lines
    local name_w=$((w - 10))
    for ((i = 1; i <= total; i++)); do
        DASHBOARD_STEP_ROWS[$i]=$row
        printf "${THEME_BORDER}  │${RESET}  %2d  ○ %-${name_w}s  ${THEME_BORDER}│${RESET}\n" \
            "$i" "Pending"
        ((row++))
    done

    # Bottom separator
    echo -e "${THEME_BORDER}  ├$(printf '─%.0s' $(seq 1 $w))┤${RESET}"
    ((row++))

    # Info line
    local log_info="Log: $INSTALL_LOG"
    local cancel_info="Ctrl+C to cancel"
    [[ "${UNATTENDED:-false}" == true ]] && cancel_info="Unattended · Ctrl+C to cancel"
    local info_pad=$((w - ${#log_info} - ${#cancel_info} - 3))
    (( info_pad < 1 )) && info_pad=1
    printf "${THEME_BORDER}  │${RESET} ${THEME_MUTED}%s${RESET}%*s ${THEME_MUTED}%s${RESET} ${THEME_BORDER}│${RESET}\n" \
        "$log_info" $info_pad "" "$cancel_info"
    ((row++))

    # Bottom border
    echo -e "${THEME_BORDER}  └$(printf '─%.0s' $(seq 1 $w))┘${RESET}"
    DASHBOARD_FRAME_END=$row

    # Start timer AFTER frame is drawn so init overhead isn't counted
    DASHBOARD_START_SEC=$(mono_now)

    tput cup $((DASHBOARD_ROW_OFFSET + DASHBOARD_FRAME_END + 1)) 0
}

dashboard_step() {
    local name="${1:-}" num="${2:-}"
    [[ -n "$name" && -n "$num" ]] || return 1
    if [[ "$DASHBOARD_PLAIN" == true ]]; then
      DASHBOARD_CURRENT_STEP=$num
      DASHBOARD_STEP_NAMES[$num]="$name"
      DASHBOARD_STEP_SEC=$(mono_now)
      DASHBOARD_STEP_STATUSES[$num]="running"
      echo "▶ Step $num: $name"
      return 0
    fi
    local total=${TOTAL_STEPS:-10}
    local w=$DASHBOARD_INNER_W

    DASHBOARD_CURRENT_STEP=$num
    DASHBOARD_STEP_NAMES[$num]="$name"
    DASHBOARD_STEP_TIMES[$num]=0
    DASHBOARD_STEP_STATUSES[$num]="running"
    DASHBOARD_STEP_SEC=$(mono_now)

    local pct=$(( (num - 1) * 100 / total ))

    # Progress bar: proportional width, capped at 50
    local bar_w=$((w * 2 / 5))
    (( bar_w < 15 )) && bar_w=15
    (( bar_w > 50 )) && bar_w=50
    local filled=$(( pct * bar_w / 100 ))
    (( filled < 0 )) && filled=0
    (( filled > bar_w )) && filled=$bar_w

    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=filled; i<bar_w; i++)); do bar+="░"; done

    # Update title with current step number
    local title="● Arch Installer"
    local step_info="Step ${num}/${total}"
    local title_pad=$((w - ${#title} - ${#step_info} - 3))
    (( title_pad < 1 )) && title_pad=1
    tput cup $((DASHBOARD_ROW_OFFSET + 1)) 0
    tput el
    printf "${THEME_BORDER}  │${RESET} ${THEME_HEADER}%s${RESET}%*s ${THEME_MUTED}%s${RESET} ${THEME_BORDER}│${RESET}" \
        "$title" $title_pad "" "$step_info"

    # Progress bar line: "  │  ███░░░  NAME  36%  │"
    local name_w=$((w - 11 - bar_w))
    (( name_w < 1 )) && name_w=1
    local disp_name="$name"
    (( ${#disp_name} > name_w )) && disp_name="${disp_name:0:$((name_w-1))}…"
    tput cup $((DASHBOARD_ROW_OFFSET + 3)) 0
    tput el
    printf "${THEME_BORDER}  │${RESET}  ${THEME_SUCCESS}%s${RESET}  ${THEME_TEXT}%-*s${RESET} %3d%%${RESET}  ${THEME_BORDER}│${RESET}" \
        "$bar" $name_w "$disp_name" $pct

    # Current step line
    local name_w2=$((w - 10))
    local step_row="${DASHBOARD_STEP_ROWS[$num]}"
    tput cup $((DASHBOARD_ROW_OFFSET + step_row)) 0
    tput el
    printf "${THEME_BORDER}  │${RESET}  %2d  ● %-${name_w2}s  ${THEME_BORDER}│${RESET}" \
        "$num" "Running..."

    tput cup $((DASHBOARD_ROW_OFFSET + DASHBOARD_FRAME_END + 1)) 0
}

dashboard_run() {
    local script_path="${1:-}"
    [[ -n "$script_path" ]] || { log_error "dashboard_run: missing script path"; return 1; }
    [[ -f "$script_path" && -r "$script_path" ]] || { log_error "dashboard_run: script not found: $script_path"; return 1; }

    # Position cursor below dashboard frame for interactive prompts (TTY only)
    if dashboard_is_tty; then
        tput cup $((DASHBOARD_ROW_OFFSET + DASHBOARD_FRAME_END + 1)) 0 2>/dev/null || true
    fi

    # Run in a subshell so exit/return in the step script doesn't kill the installer
    # stdout/stderr go to the log; interactive prompts (gum, read) use /dev/tty directly
    (
      source "$script_path"
    ) >> "$INSTALL_LOG" 2>&1
    local ret=$?
    return $ret
}

dashboard_ok() {
    local num=$DASHBOARD_CURRENT_STEP
    local elapsed=0
    [ "$DASHBOARD_STEP_SEC" -ge 0 ] && elapsed=$(( $(mono_now) - DASHBOARD_STEP_SEC ))
    (( elapsed < 0 )) && elapsed=0
    if [[ "$DASHBOARD_PLAIN" == true ]]; then
      DASHBOARD_STEP_STATUSES[$num]="ok"
      DASHBOARD_STEP_TIMES[$num]=$elapsed
      echo "✓ Step $num done (${elapsed}s)"
      if declare -f log_to_file >/dev/null 2>&1; then
        log_to_file "STEP_TIMING: Step $num (${DASHBOARD_STEP_NAMES[$num]:-unknown}) completed in ${elapsed}s"
      fi
      return 0
    fi
    local w=$DASHBOARD_INNER_W
    DASHBOARD_STEP_STATUSES[$num]="ok"
    DASHBOARD_STEP_TIMES[$num]=$elapsed

    local time_str="$(format_time "$elapsed")"
    local step_row="${DASHBOARD_STEP_ROWS[$num]}"
    local name="${DASHBOARD_STEP_NAMES[$num]}"

    local name_w=$((w - 17))
    tput cup $((DASHBOARD_ROW_OFFSET + step_row)) 0
    tput el
    printf "${THEME_BORDER}  │${RESET}  %2d  ${THEME_SUCCESS}✓${RESET} %-${name_w}s ${THEME_MUTED}%6s${RESET}  ${THEME_BORDER}│${RESET}" \
        "$num" "$name" "$time_str"

    tput cup $((DASHBOARD_ROW_OFFSET + DASHBOARD_FRAME_END + 1)) 0
    if declare -f log_to_file >/dev/null 2>&1; then
      log_to_file "STEP_TIMING: Step $num ($name) completed in ${elapsed}s"
    fi
}

dashboard_fail() {
    local num=$DASHBOARD_CURRENT_STEP
    if [[ "$DASHBOARD_PLAIN" == true ]]; then
      DASHBOARD_STEP_STATUSES[$num]="fail"
      DASHBOARD_STEP_TIMES[$num]=0
      echo "✗ Step $num failed"
      if declare -f log_to_file >/dev/null 2>&1; then
        log_to_file "STEP_TIMING: Step $num (${DASHBOARD_STEP_NAMES[$num]:-unknown}) failed"
      fi
      return 0
    fi
    local elapsed=0
    [ "$DASHBOARD_STEP_SEC" -ge 0 ] && elapsed=$(( $(mono_now) - DASHBOARD_STEP_SEC ))
    (( elapsed < 0 )) && elapsed=0
    local w=$DASHBOARD_INNER_W
    DASHBOARD_STEP_STATUSES[$num]="fail"
    DASHBOARD_STEP_TIMES[$num]=$elapsed

    local time_str="$(format_time "$elapsed")"
    local step_row="${DASHBOARD_STEP_ROWS[$num]}"
    local name="${DASHBOARD_STEP_NAMES[$num]}"

    local name_w=$((w - 17))
    tput cup $((DASHBOARD_ROW_OFFSET + step_row)) 0
    tput el
    printf "${THEME_BORDER}  │${RESET}  %2d  ${THEME_ERROR}✗${RESET} %-${name_w}s ${THEME_MUTED}%6s${RESET}  ${THEME_BORDER}│${RESET}" \
        "$num" "$name" "$time_str"

    tput cup $((DASHBOARD_ROW_OFFSET + DASHBOARD_FRAME_END + 1)) 0
    if declare -f log_to_file >/dev/null 2>&1; then
      log_to_file "STEP_TIMING: Step $num ($name) failed after ${elapsed}s"
    fi
}

dashboard_skip() {
    local msg="${1:-Already completed}"
    local num=$DASHBOARD_CURRENT_STEP
    if [[ "$DASHBOARD_PLAIN" == true ]]; then
      DASHBOARD_STEP_STATUSES[$num]="skip"
      DASHBOARD_STEP_TIMES[$num]=0
      echo "◇ Step $num skipped — $msg"
      if declare -f log_to_file >/dev/null 2>&1; then
        log_to_file "STEP_TIMING: Step $num (${DASHBOARD_STEP_NAMES[$num]:-unknown}) skipped — $msg"
      fi
      return 0
    fi
    local w=$DASHBOARD_INNER_W
    DASHBOARD_STEP_STATUSES[$num]="skip"
    DASHBOARD_STEP_TIMES[$num]=0

    local step_row="${DASHBOARD_STEP_ROWS[$num]}"

    local name_w=$((w - 10))
    local disp_msg="$msg"
    (( ${#disp_msg} > name_w )) && disp_msg="${disp_msg:0:$((name_w-1))}…"

    tput cup $((DASHBOARD_ROW_OFFSET + step_row)) 0
    tput el
    printf "${THEME_BORDER}  │${RESET}  %2d  ${THEME_MUTED}◇${RESET} %-${name_w}s  ${THEME_BORDER}│${RESET}" \
        "$num" "$disp_msg"

    tput cup $((DASHBOARD_ROW_OFFSET + DASHBOARD_FRAME_END + 1)) 0
    if declare -f log_to_file >/dev/null 2>&1; then
      log_to_file "STEP_TIMING: Step $num (${DASHBOARD_STEP_NAMES[$num]:-unknown}) skipped — $msg"
    fi
}

dashboard_warn() {
    local msg="${1:-Warning}"
    local num=$DASHBOARD_CURRENT_STEP
    if [[ "$DASHBOARD_PLAIN" == true ]]; then
      DASHBOARD_STEP_STATUSES[$num]="warn"
      echo "⚠ Step $num warning — $msg"
      return 0
    fi
    local elapsed=0
    [ "$DASHBOARD_STEP_SEC" -ge 0 ] && elapsed=$(( $(mono_now) - DASHBOARD_STEP_SEC ))
    (( elapsed < 0 )) && elapsed=0
    local w=$DASHBOARD_INNER_W
    DASHBOARD_STEP_STATUSES[$num]="warn"
    DASHBOARD_STEP_TIMES[$num]=$elapsed

    local time_str="$(format_time "$elapsed")"
    local step_row="${DASHBOARD_STEP_ROWS[$num]}"
    local name="${DASHBOARD_STEP_NAMES[$num]}"

    local name_w=$((w - 17))
    tput cup $((DASHBOARD_ROW_OFFSET + step_row)) 0
    tput el
    printf "${THEME_BORDER}  │${RESET}  %2d  ${THEME_WARN}⚠${RESET} %-${name_w}s ${THEME_MUTED}%6s${RESET}  ${THEME_BORDER}│${RESET}" \
        "$num" "$name" "$time_str"

    tput cup $((DASHBOARD_ROW_OFFSET + DASHBOARD_FRAME_END + 1)) 0
}

dashboard_finish() {
    if dashboard_is_tty; then clear; fi

    local total=${TOTAL_STEPS:-10}
    local success=0 fail=0 skip=0 warn=0

    for ((i = 1; i <= total; i++)); do
        [[ -v DASHBOARD_STEP_STATUSES[$i] ]] || continue
        case "${DASHBOARD_STEP_STATUSES[$i]}" in
            ok)   ((success++)) ;;
            fail) ((fail++)) ;;
            skip) ((skip++)) ;;
            warn) ((warn++)) ;;
        esac
    done

    local wall_time=0
    if [[ "$DASHBOARD_START_SEC" -ge 0 ]]; then
        wall_time=$(( $(mono_now) - DASHBOARD_START_SEC ))
    fi
    (( wall_time < 0 )) && wall_time=0
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    local w=$((cols - 4))
    (( w < 50 )) && w=50
    (( w > 120 )) && w=120

    local title
    if [ "$fail" -gt 0 ]; then
        title="Installation Completed — ${fail} step(s) failed"
    else
        title="Installation Complete"
    fi

    echo -e "${THEME_BORDER}  ╔$(printf '═%.0s' $(seq 1 $w))╗${RESET}"
    local title_pad=$(( (w - ${#title}) / 2 ))
    (( title_pad < 1 )) && title_pad=1
    printf "${THEME_BORDER}  ║${RESET}%*s${THEME_HEADER}%s${RESET}%*s${THEME_BORDER}║${RESET}\n" \
        $title_pad '' "$title" $((w - title_pad - ${#title})) ''
    echo -e "${THEME_BORDER}  ╚$(printf '═%.0s' $(seq 1 $w))╝${RESET}"
    echo ""

    for ((i = 1; i <= total; i++)); do
        [[ -v DASHBOARD_STEP_STATUSES[$i] ]] || continue
        local name="${DASHBOARD_STEP_NAMES[$i]:-Step $i}"
        local st="${DASHBOARD_STEP_STATUSES[$i]}"
        local tm="${DASHBOARD_STEP_TIMES[$i]:-0}"
        local icon color
        case "$st" in
            ok)   icon="✓"; color="$THEME_SUCCESS" ;;
            fail) icon="✗"; color="$THEME_ERROR" ;;
            skip) icon="◇"; color="$THEME_MUTED" ;;
            warn) icon="⚠"; color="$THEME_WARN" ;;
            *)    icon="?"; color="$THEME_MUTED" ;;
        esac
        local time_str
        if [ "$st" = "skip" ]; then
            time_str="  --  "
        else
            time_str="$(format_time "$tm")"
            time_str=$(printf "%6s" "$time_str")
        fi
        printf "${color}  %s  Step %2d: %-28s${THEME_MUTED} %s${RESET}\n" \
            "$icon" "$i" "$name" "$time_str"
    done

    echo ""
    echo -e "${THEME_MUTED}  $(printf '─%.0s' $(seq 1 $w))${RESET}"
    echo ""
    echo -e "${THEME_TEXT}    ${success} completed, ${fail} failed, ${warn} warnings, ${skip} skipped${RESET}  |  ${THEME_SECONDARY}Total: $(format_time $wall_time)${RESET}"
    echo ""

    log_to_file "Installation finished. $success completed, $fail failed, $warn warnings, $skip skipped in $(format_time $wall_time)"
    for ((i = 1; i <= total; i++)); do
        [[ -v DASHBOARD_STEP_STATUSES[$i] ]] || continue
        log_to_file "STEP_SUMMARY: Step $i (${DASHBOARD_STEP_NAMES[$i]:-unknown}) = ${DASHBOARD_STEP_STATUSES[$i]} in ${DASHBOARD_STEP_TIMES[$i]:-0}s"
    done
}
