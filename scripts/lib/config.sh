#!/bin/bash
set -uo pipefail

# ============================================================================
# Configuration Library - YAML parsing and configuration management
# ============================================================================

# Check if yq is available
has_yq() {
    command -v yq &>/dev/null
}

# Read YAML array of packages
# Usage: read_yaml_packages "file.yaml" ".path.to.packages" output_array
read_yaml_packages() {
    local yaml_file="$1"
    local yaml_path="$2"
    local -n packages_array="$3"
    
    packages_array=()
    
    if ! has_yq; then
        log_error "yq is required for YAML parsing"
        return 1
    fi
    
    if [ ! -f "$yaml_file" ]; then
        log_error "YAML file not found: $yaml_file"
        return 1
    fi
    
    local yq_output
    yq_output=$(yq -r "$yaml_path[]" "$yaml_file" 2>/dev/null)
    
    if [[ $? -eq 0 && -n "$yq_output" ]]; then
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            packages_array+=("$pkg")
        done <<<"$yq_output"
    fi
}

# Read YAML array with descriptions
# Usage: read_yaml_packages_with_desc "file.yaml" ".path.to.packages" packages_array descriptions_array
read_yaml_packages_with_desc() {
    local yaml_file="$1"
    local yaml_path="$2"
    local -n packages_array="$3"
    local -n descriptions_array="$4"
    
    packages_array=()
    descriptions_array=()
    
    if ! has_yq; then
        log_error "yq is required for YAML parsing"
        return 1
    fi
    
    if [ ! -f "$yaml_file" ]; then
        log_error "YAML file not found: $yaml_file"
        return 1
    fi
    
    local yq_output
    yq_output=$(yq -r "$yaml_path[] | [.name, .description] | @tsv" "$yaml_file" 2>/dev/null)
    
    if [[ $? -eq 0 && -n "$yq_output" ]]; then
        while IFS=$'\t' read -r name description; do
            [[ -z "$name" ]] && continue
            packages_array+=("$name")
            descriptions_array+=("$description")
        done <<<"$yq_output"
    fi
}

# Read single YAML value
# Usage: read_yaml_value "file.yaml" ".path.to.value"
read_yaml_value() {
    local yaml_file="$1"
    local yaml_path="$2"
    
    if ! has_yq; then
        log_error "yq is required for YAML parsing"
        return 1
    fi
    
    if [ ! -f "$yaml_file" ]; then
        log_error "YAML file not found: $yaml_file"
        return 1
    fi
    
    yq -r "$yaml_path" "$yaml_file" 2>/dev/null
}

# Check if YAML key exists
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

# Get all keys from YAML object
# Usage: get_yaml_keys "file.yaml" ".path.to.object"
get_yaml_keys() {
    local yaml_file="$1"
    local yaml_path="$2"
    
    if ! has_yq; then
        log_error "yq is required for YAML parsing"
        return 1
    fi
    
    if [ ! -f "$yaml_file" ]; then
        log_error "YAML file not found: $yaml_file"
        return 1
    fi
    
    yq eval "$yaml_path | keys | .[]" "$yaml_file" 2>/dev/null
}
