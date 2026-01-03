@echo off
REM Windows batch file to prepare LinuxInstaller scripts for Linux execution
REM This script creates a Linux script that will make all .sh files executable

echo Creating Linux executable permissions script...

(
echo #!/bin/bash
echo echo "Making LinuxInstaller scripts executable..."
echo.
echo # Main install script
echo chmod +x install.sh
echo echo "✓ Made install.sh executable"
echo.
echo # All scripts in the scripts directory
echo for script in scripts/*.sh; do
echo     if [ -f "$script" ]; then
echo         chmod +x "$script"
echo         echo "✓ Made $script executable"
echo     fi
echo done
echo.
echo echo "All scripts are now executable!"
echo echo "You can now run: sudo ./install.sh"
) > make_executable.sh

echo ✓ Created make_executable.sh
echo.
echo To use on Linux:
echo 1. Copy the entire linuxinstaller folder to a Linux system
echo 2. Run: bash make_executable.sh
echo 3. Then run: sudo ./install.sh
echo.
pause
