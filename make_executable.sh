#!/bin/bash
# Make all LinuxInstaller scripts executable

echo "Making LinuxInstaller scripts executable..."

# Main install script
chmod +x install.sh
echo "✓ Made install.sh executable"

# All scripts in the scripts directory
for script in scripts/*.sh; do
    if [ -f "$script" ]; then
        chmod +x "$script"
        echo "✓ Made $script executable"
    fi
done

echo ""
echo "All scripts are now executable!"
echo "You can now run: sudo ./install.sh"
