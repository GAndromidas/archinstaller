#!/bin/bash
set -uo pipefail

# YAML parsing and configuration management

has_yq() {
    command -v yq &>/dev/null
}

# Fallback plain-text parser when yq is unavailable (README promise).
# Handles the two shapes used in this repo:
#   - "- name: foo" (+ optional `description:` line)  -> packages with desc
#   - "- foo" (bare string)                           -> plain package lists
# Path-aware: `.desktop_environments.kde.install` narrows through each
# level (desktop_environments -> kde -> install) so same-named keys in
# sibling blocks (gnome/cosmic `install:`) are never mixed in.
_yaml_narrow_block() {
    # $1 = key, reads lines on stdin, prints lines under `key:` (greater indent)
    # Allows trailing comments (`generic: # Fallback...`).
    local key="$1"
    awk -v key="$key" '
        !in_sec && $0 ~ "^[[:space:]]*" key ":[[:space:]]*(#.*)?$" {
            match($0, /[^[:space:]]/); key_indent = RSTART - 1;
            in_sec = 1; next;
        }
        in_sec {
            if ($0 ~ /^[[:space:]]*$/) next;
            match($0, /[^[:space:]]/); cur = RSTART - 1;
            if (cur <= key_indent) exit;
            print;
        }
    '
}

_yaml_fallback_section_lines() {
    local yaml_file="$1" section="$2"
    local path="${section#.}"
    local IFS='.' parts=()
    # shellcheck disable=SC2206
    parts=($path)
    local content
    content=$(cat "$yaml_file")
    local p
    for p in "${parts[@]}"; do
        content=$(echo "$content" | _yaml_narrow_block "$p")
        [[ -z "$content" ]] && break
    done
    echo "$content"
}

_yaml_fallback_packages_with_desc() {
    local yaml_file="$1" yaml_path="$2" out_pkgs="$3" out_descs="$4"
    local -n _fp="$out_pkgs" _fd="$out_descs"
    _fp=(); _fd=()
    local name="" desc=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.+)$ ]]; then
            [[ -n "$name" ]] && { _fp+=("$name"); _fd+=("$desc"); }
            name="${BASH_REMATCH[1]//\"/}"; name="${name//\'/}"
            name=$(echo "$name" | xargs)
            desc=""
        elif [[ "$line" =~ ^[[:space:]]*description:[[:space:]]*(.+)$ ]] && [[ -n "$name" ]]; then
            desc="${BASH_REMATCH[1]//\"/}"; desc="${desc//\'/}"
            desc=$(echo "$desc" | xargs)
        elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]*([^[:space:]#][^[:space:]#]*)$ ]] && [[ -z "$name" || "$line" != *"name:"* ]]; then
            # bare "- pkg" line (DE install/remove lists) — flush pending first
            [[ -n "$name" ]] && { _fp+=("$name"); _fd+=("$desc"); name=""; desc=""; }
            local bare="${BASH_REMATCH[1]}"
            bare=$(echo "$bare" | xargs)
            [[ -n "$bare" ]] && { _fp+=("$bare"); _fd+=(""); }
        fi
    done < <(_yaml_fallback_section_lines "$yaml_file" "$yaml_path"; echo "")
    [[ -n "$name" ]] && { _fp+=("$name"); _fd+=("$desc"); }
}

# Usage: read_yaml_packages "file.yaml" ".path.to.packages" output_array
read_yaml_packages() {
    local yaml_file="$1"
    local yaml_path="$2"
    # shellcheck disable=SC2178
    # nameref to caller's array; assignment is array context
    local -n packages_array="$3"

    packages_array=()

    if [ ! -f "$yaml_file" ]; then
        log_error "YAML file not found: $yaml_file"
        return 1
    fi

    if ! has_yq; then
        local fallback_descs=()
        _yaml_fallback_packages_with_desc "$yaml_file" "$yaml_path" "$3" fallback_descs
        : "${fallback_descs[@]}" # reference to avoid unused warning; descriptions discarded by design
        [[ ${#packages_array[@]} -gt 0 ]] || log_debug "yq missing — used fallback parser for $yaml_path (${#packages_array[@]} pkgs)"
        return 0
    fi

    local yq_output
    yq_output=$(yq -r "${yaml_path}[]" "$yaml_file" 2>/dev/null)

    if [[ $? -eq 0 && -n "$yq_output" ]]; then
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            packages_array+=("$pkg")
        done <<<"$yq_output"
    fi
}

# Usage: read_yaml_packages_with_desc "file.yaml" ".path.to.packages" packages_array descriptions_array
read_yaml_packages_with_desc() {
    local yaml_file="$1"
    local yaml_path="$2"
    # shellcheck disable=SC2178
    # namerefs to caller's arrays
    local -n packages_array="$3"
    # shellcheck disable=SC2178
    local -n descriptions_array="$4"

    packages_array=()
    descriptions_array=()

    if [ ! -f "$yaml_file" ]; then
        log_error "YAML file not found: $yaml_file"
        return 1
    fi

    if ! has_yq; then
        _yaml_fallback_packages_with_desc "$yaml_file" "$yaml_path" "$3" "$4"
        return 0
    fi
    
    local yq_output
    yq_output=$(yq -r "${yaml_path}[] | [.name, .description] | @tsv" "$yaml_file" 2>/dev/null)
    
    if [[ $? -eq 0 && -n "$yq_output" ]]; then
        while IFS=$'\t' read -r name description; do
            [[ -z "$name" ]] && continue
            packages_array+=("$name")
            descriptions_array+=("$description")
        done <<<"$yq_output"
    fi
}

# Usage: read_yaml_value "file.yaml" ".path.to.value"
read_yaml_value() {
    local yaml_file="$1"
    local yaml_path="$2"

    if [ ! -f "$yaml_file" ]; then
        log_error "YAML file not found: $yaml_file"
        return 1
    fi

    if ! has_yq; then
        log_debug "yq missing — read_yaml_value fallback returns empty for $yaml_path"
        return 1
    fi

    yq -r "$yaml_path" "$yaml_file" 2>/dev/null
}

# Usage: yaml_key_exists "file.yaml" ".path.to.key"
yaml_key_exists() {
    local yaml_file="$1"
    local yaml_path="$2"
    
    if ! has_yq; then
        return 1
    fi
    
    if [ ! -f "$yaml_file" ]; then
        return 1
    fi
    
    yq eval "$yaml_path" "$yaml_file" &>/dev/null
}

# Usage: get_yaml_keys "file.yaml" ".path.to.object"
get_yaml_keys() {
    local yaml_file="$1"
    local yaml_path="$2"

    if [ ! -f "$yaml_file" ]; then
        log_error "YAML file not found: $yaml_file"
        return 1
    fi

    if ! has_yq; then
        log_debug "yq missing — get_yaml_keys fallback unavailable for $yaml_path"
        return 1
    fi

    yq eval "$yaml_path | keys | .[]" "$yaml_file" 2>/dev/null
}
