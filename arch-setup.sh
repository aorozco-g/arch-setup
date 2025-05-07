#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME="arch_setup"
TEMP_DIR="$(mktemp -d -t "${SCRIPT_NAME}".XXXXXX)"
readonly PROGRESS_FILE="$HOME/.arch_setup_progress"

trap 'echo "[ERROR] Script failed at line ${LINENO}. Exiting..." >&2; save_progress; rm -rf "$TEMP_DIR"; exit 1' ERR
trap 'rm -rf "$TEMP_DIR"' EXIT

PACMAN_PACKAGES=(
    git base-devel curl jq unzip tar unrar fzf linux-headers 
    nvidia-open-dkms nvidia-utils lib32-nvidia-utils vulkan-icd-loader 
    lib32-vulkan-icd-loader nvidia-settings xdg-desktop-portal flatpak 
    powerdevil tuned tuned-ppd vim wget htop firefox 
    libreoffice-fresh vlc spotify-launcher telegram-desktop python 
    python-pip ffmpegthumbs kdegraphics-thumbnailers liquidctl gwenview 
    qbittorrent pacman-contrib proton-vpn-gtk-app torbrowser-launcher 
    kalk filelight kvantum papirus-icon-theme lutris umu-launcher steam 
    ttf-liberation gamemode goverlay mangohud noto-fonts noto-fonts-extra 
    noto-fonts-cjk noto-fonts-emoji discord kitty zsh zsh-completions 
    zsh-autosuggestions zsh-syntax-highlighting pkgfile shellcheck elisa
)

AUR_PACKAGES=(
    visual-studio-code-bin savedesktop gwe webapp-manager zapzap 
    protonplus zsh-theme-powerlevel10k-git
)

# Saves the current installation progress to a file for resuming later
save_progress() {
    echo "$CURRENT_STEP" > "$PROGRESS_FILE"
    log "Progress saved. To resume from this point, run the script again."
}

# Loads the previous installation progress from file if it exists
load_progress() {
    if [[ -f "$PROGRESS_FILE" ]]; then
        LAST_COMPLETED=$(cat "$PROGRESS_FILE")
        log "Found saved progress. Resuming from step: $LAST_COMPLETED"
    else
        LAST_COMPLETED="start"
        log "No saved progress found. Starting from the beginning."
    fi
}

# Determines if a step should be executed based on saved progress
# Returns 0 if step should run, 1 if it should be skipped
should_execute() {
    local step=$1
    local found_last=false
    
    # If we're just starting, execute the step
    if [[ "$LAST_COMPLETED" == "start" ]]; then
        CURRENT_STEP="$step"
        return 0
    fi
    
    # Check if we've passed the last completed step in the steps array
    # by iterating through the steps array in main()
    for step_info in "${steps[@]}"; do
        local current_step
        IFS=':' read -r current_step _ <<< "$step_info"
        
        # If we found the last completed step, mark it
        if [[ "$current_step" == "$LAST_COMPLETED" ]]; then
            found_last=true
            continue
        fi
        
        # If this is our target step and we've already passed the last completed step
        if [[ "$current_step" == "$step" && "$found_last" == "true" ]]; then
            CURRENT_STEP="$step"
            return 0
        fi
    done
    
    log "Skipping already completed step: $step"
    return 1
}

cd "$TEMP_DIR" || { log "Failed to change to temporary directory"; exit 1; }

# Logs a message with timestamp to track script progress
log() {
    echo "[$(date -Iseconds)] $1"
}

# Executes a command with proper error handling and logging
# Parameters: command, error message, success message (optional)
run_command() {
    local cmd="$1"
    local error_msg="$2"
    local success_msg="${3:-Command executed successfully}"
    
    if eval "$cmd"; then
        log "$success_msg"
        return 0
    else
        log "$error_msg"
        return 1
    fi
}

# Run a command and log the result
try_command() {
    local cmd="$1"
    local error_msg="$2"
    local success_msg="${3:-}"
    
    log "Executing: $cmd"
    if eval "$cmd"; then
        [[ -n "$success_msg" ]] && log "$success_msg"
        return 0
    else
        log "$error_msg"
        return 1
    fi
}

# Helper function to enable systemd services with error handling
# Parameters: service_name, [socket] (optional flag to enable socket too)
enable_service() {
    local service="$1"
    local enable_socket=${2:-false}
    
    if ! sudo systemctl enable --now "$service"; then
        log "Failed to enable $service"
        return 1
    fi
    
    if $enable_socket && ! sudo systemctl enable "$service.socket"; then
        log "Failed to enable $service.socket"
        return 1
    fi
    
    return 0
}

# Helper function to add user to a group if not already a member
# Parameters: group_name
add_user_to_group() {
    local group="$1"
    
    if ! groups "$USER" | grep -q "\b$group\b"; then
        if ! sudo usermod -aG "$group" "$USER"; then
            log "Failed to add user to $group group"
            return 1
        fi
        log "Added user to $group group"
    else
        log "User already in $group group"
    fi
    
    return 0
}

# Helper function to modify configuration files
# Parameters: file_path, search_pattern, replacement (optional)
modify_config() {
    local file="$1"
    local pattern="$2"
    # Note: $3 (replacement) is not used in this function but kept for API consistency
    
    if ! run_command "sudo sed -i \"$pattern\" \"$file\"" \
        "Failed to modify configuration in $file" \
        "Configuration in $file modified successfully"; then
        return 1
    fi
    
    return 0
}

# Append content to a file with error handling
append_to_file() {
    local file="$1"
    local content="$2"
    
    if ! echo "$content" >> "$file"; then
        log "Failed to append to $file"
        return 1
    fi
    return 0
}

# Sets up WiFi connection using NetworkManager
# Installs NetworkManager if not present and guides through connection setup
connect_wifi() {
    log "Establishing network connectivity via NetworkManager"
    
    if ! command -v nmcli &> /dev/null; then
        log "NetworkManager not found. Installing..."
        # Use run_command for consistent error handling
        run_command "sudo pacman -S --noconfirm --needed networkmanager" \
            "Failed to install NetworkManager" \
            "NetworkManager installed successfully"
        run_command "sudo systemctl enable --now NetworkManager" \
            "Failed to enable NetworkManager service" \
            "NetworkManager service enabled and started"
        sleep 2
    fi
    
    local interfaces=()
    while read -r line; do
        interfaces+=("$line")
    done < <(nmcli device | grep wifi | awk '{print $1}')
    local device=""
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log "No wireless interfaces found"
        return 1
    elif [[ ${#interfaces[@]} -eq 1 ]]; then
        device="${interfaces[0]}"
        log "Using wireless interface: $device"
    else
        echo "Multiple wireless interfaces found:"
        for i in "${!interfaces[@]}"; do
            echo "[$((i+1))] ${interfaces[$i]}"
        done
        
        local choice
        read -r -p "Select interface [1-${#interfaces[@]}]: " choice
        if [[ $choice -ge 1 && $choice -le ${#interfaces[@]} ]]; then
            device="${interfaces[$((choice-1))]}"
            log "Selected wireless interface: $device"
        else
            log "Invalid selection. Using first interface: ${interfaces[0]}"
            device="${interfaces[0]}"
        fi
    fi
    
    log "Enabling wireless interface $device"
    sudo nmcli radio wifi on
    sudo nmcli device set "$device" autoconnect yes
    
    local connected=false
    while ! $connected; do
        log "Scanning for available networks..."
        sudo nmcli device wifi rescan
        sleep 3
        
        echo -e "\n===== Available Wi-Fi Networks =====\n"
        nmcli -f SSID,SIGNAL,SECURITY device wifi list | sort -k2 -nr | head -n 15
        echo -e "\n==================================="
        
        local ssid
        echo -e "\nEnter the SSID of the network you want to connect to,"
        echo "or press Enter to manually enter an SSID:"
        read -r -p "SSID: " ssid
        
        if [[ -z "$ssid" ]]; then
            read -r -p "Enter hidden SSID: " ssid
            if [[ -z "$ssid" ]]; then
                log "No SSID provided. Aborting."
                return 1
            fi
        fi
        
        local password
        read -r -s -p "Enter password for '$ssid' (leave empty for open networks): " password
        echo
        
        sudo nmcli connection delete "$ssid" &>/dev/null || true
        
        log "Attempting to connect to $ssid..."
        
        local connect_cmd
        local network_type
        if [[ -z "$password" ]]; then
            connect_cmd="sudo nmcli device wifi connect \"$ssid\" ifname \"$device\""
            network_type="open"
        else
            connect_cmd="sudo nmcli device wifi connect \"$ssid\" password \"$password\" ifname \"$device\""
            network_type="secured"
        fi
        
        if eval "$connect_cmd"; then
            log "Successfully connected to $network_type network: $ssid"
            connected=true
        else
            log "Failed to connect to $network_type network: $ssid"
            read -r -p "Would you like to try again? (y/n): " retry
            if [[ "$retry" != "y" && "$retry" != "Y" ]]; then
                return 1
            fi
        fi
    done
    
    return 0
}

# Enables and starts the Bluetooth service for wireless device connectivity
enable_bluetooth() {
    log "Enabling Bluetooth service"
    run_command "sudo systemctl enable --now bluetooth" "Failed to enable Bluetooth service" "Bluetooth service enabled and started"
    return $?
}

# Pairs a Bluetooth mouse interactively using expect
pair_bluetooth_mouse() {
    log "Starting Bluetooth mouse pairing process"
    
    # Install required packages if not already installed
    log "Installing required Bluetooth utilities"
    if ! run_command "sudo pacman -S --noconfirm --needed bluez-utils expect" \
        "Failed to install Bluetooth utilities" \
        "Bluetooth utilities installed successfully"; then
        return 1
    fi
    
    # Create a temporary expect script
    local expect_script="$TEMP_DIR/pair_bluetooth.exp"
    cat > "$expect_script" << 'EOF'
#!/usr/bin/expect -f

# Set global timeout for expect commands
set timeout 10

# Enable logging of expect interactions (1=on, 0=off)
log_user 1

# Start bluetoothctl
spawn bluetoothctl

# Wait for prompt - be more flexible with what we expect
expect {
    "Agent registered" {
        send_user "\nBluetooth controller initialized\n"
    }
    timeout {
        send_user "\nTimeout waiting for Bluetooth controller initialization\n"
        exit 1
    }
}

# Set agent
send "agent KeyboardOnly\r"
expect {
    "Agent registered" {}
    "Agent is already registered" {}
    timeout {
        send_user "\nTimeout setting agent\n"
        exit 1
    }
}

# Set as default agent
send "default-agent\r"
expect "Default agent request successful"

# Power on
send "power on\r"
expect {
    "Changing power on succeeded" {
        send_user "\nBluetooth powered on\n"
    }
    "No default controller available" {
        send_user "\nNo Bluetooth controller available. Please check your hardware.\n"
        exit 1
    }
    timeout {
        send_user "\nTimeout powering on Bluetooth\n"
        exit 1
    }
}

# Start scanning
send "scan on\r"
expect "Discovery started"
send_user "\nScanning for Bluetooth devices...\n"

# Function to scan for devices and display them
proc scan_and_show_devices {{initial_scan 0}} {
    global timeout
    set saved_timeout $timeout
    
    # For initial scan, wait for devices to be discovered
    if {$initial_scan} {
        log_user 0
        for {set i 1} {$i <= 10} {incr i} {
            send_user "."
            sleep 1
            # Silently consume any output during scanning
            expect {
                -re {.*} {}
                timeout {}
            }
        }
        send_user "\n"
        
        # Turn off scan mode after initial discovery to avoid continuous notifications
        send "scan off\r"
        expect "SetDiscoveryFilter success"
    }
    
    # Clear any pending output before showing devices
    expect {
        -re {.*} {}
        timeout {}
    }
    
    # Turn off logging to prevent duplicate output
    log_user 0
    
    # Show devices
    send "devices\r"
    
    # Wait for the prompt to return and capture the output
    expect {
        -re {.*\[bluetoothctl\]} {
            # Get everything before the prompt
            set full_output $expect_out(buffer)
            
            # Extract device lines
            set device_list ""
            foreach line [split $full_output "\n"] {
                if {[regexp {Device ([0-9A-Fa-f:]+) (.+)} $line -> mac name]} {
                    append device_list "$line\n"
                }
            }
        }
        timeout {
            send_user "\nTimeout waiting for device list\n"
            set device_list ""
        }
    }
    
    # Turn logging back on for user interaction
    log_user 1
    
    # Display the device list
    send_user "\n=== Available Bluetooth Devices ===\n"
    if {$device_list eq ""} {
        send_user "No devices found. Try rescanning.\n"
    } else {
        send_user "$device_list"
    }
    send_user "================================\n"
    
    # Restore original timeout
    set timeout $saved_timeout
    
    return $device_list
}

# Initial scan with waiting for devices
set device_list [scan_and_show_devices 1]

# Ask for MAC address or rescan option
while {1} {
    # Use longer timeout for user input
    set timeout 30
    
    send_user "\nEnter the MAC address of your mouse from the list above,\n"
    send_user "or type 'rescan' to search for devices again: "

    # Read user input with longer timeout
    expect_user -re {(.+)\r?\n}
    set input [string trim $expect_out(1,string)]
    
    # Reset timeout to default for other operations
    set timeout 10

# Check if user wants to rescan
if {[string tolower $input] eq "rescan"} {
    # Turn on scanning again
    send_user "\nRescanning for devices...\n"
    send "scan on\r"
    expect "Discovery started"
    
    # Use the scan_and_show_devices function with initial_scan=1 to handle the scanning process
    set device_list [scan_and_show_devices 1]
    continue
}

# Assume input is a MAC address
set mac $input

# Validate MAC address format
if {![regexp {^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$} $mac]} {
    send_user "\nInvalid MAC address format. Please use the format XX:XX:XX:XX:XX:XX\n"
    continue
}

send_user "\nPairing with device: $mac\n"
break
}

# Use longer timeout for pairing and connection operations
set timeout 30

# Pair with device
send "pair $mac\r"
expect {
    "Too many arguments" {
        send_user "\nInvalid MAC address format. Please enter just the MAC address.\n"
        send "exit\r"
        exit 1
    }
    "Failed to pair" {
        send_user "\nFailed to pair with device. Please try again.\n"
        send "exit\r"
        exit 1
    }
    "Pairing successful" {
        send_user "\nPairing successful!\n"
    }
    timeout {
        send_user "\nPairing timed out. The device might need to be in pairing mode.\n"
        send "exit\r"
        exit 1
    }
}

# Connect to device
send "connect $mac\r"
expect {
    "Failed to connect" {
        send_user "\nFailed to connect to device.\n"
        send "exit\r"
        exit 1
    }
    "Connection successful" {
        send_user "\nConnection successful!\n"
    }
    timeout {
        send_user "\nConnection timed out.\n"
        send "exit\r"
        exit 1
    }
}

# Reset timeout to default after critical operations
set timeout 10

# Trust device for automatic reconnection
send "trust $mac\r"
expect {
    "trust succeeded" {
        send_user "\nDevice trusted for automatic reconnection.\n"
    }
    timeout {
        send_user "\nTrust command timed out.\n"
    }
}

# Exit bluetoothctl
send "exit\r"
expect eof
EOF

    # Make the expect script executable
    chmod +x "$expect_script"
    
    # Run the expect script
    log "Starting interactive Bluetooth pairing process"
    if "$expect_script"; then
        log "Bluetooth mouse paired successfully"
        return 0
    else
        log "Failed to pair Bluetooth mouse"
        return 1
    fi
}

# Optimizes pacman configuration by enabling multilib repo and improving download settings
configure_pacman() {
    log "Optimizing pacman settings"
    
    # Direct approach with explicit sed commands
    run_command "sudo sed -i \
        -e '/^\\s*#\\s*\\[multilib\\]/,/^\\s*#Include/s/^#//' \
        -e 's/^#VerbosePkgLists/VerbosePkgLists/' \
        -e 's/^ParallelDownloads = 5/ParallelDownloads = 10/' \
        /etc/pacman.conf" \
        "Failed to configure pacman" \
        "Pacman optimizations applied: multilib enabled, verbose output, parallel downloads increased"

        # Sync package databases
    log "Syncing package databases"
    run_command "sudo pacman -Syy" \
        "Failed to sync package databases" \
        "Package databases synchronized successfully"

    return $?
}

# Sets up reflector to automatically select the fastest package mirrors
# Creates configuration and systemd timer for periodic mirror updates
setup_reflector() {
    log "Setting up mirror optimization"
    if ! run_command "sudo pacman -S --needed --noconfirm reflector rsync" "Failed to install reflector"; then
        return 1
    fi
    
    run_command "sudo systemctl enable reflector.timer" "Failed to enable reflector timer"
    run_command "sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup" "Failed to backup mirror list"
    log "Updating mirror list"
    if run_command "sudo reflector --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist" "Failed to update mirror list"; then
        log "Mirror list updated successfully"
        
        # Sync and test package databases
        if run_command "sudo pacman -Syy && pacman -Ss base-devel > /dev/null 2>&1" "Package database sync/test failed"; then
            # Update system packages
            run_command "sudo pacman -Su --noconfirm" "System update failed"
            log "Mirror optimization complete"
        else
            log "Database issue - restoring backup mirrors"
            if run_command "sudo cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist && sudo pacman -Syy" "Failed to restore mirrors"; then
                log "Continuing with original mirrors"
            fi
        fi
    else
        log "Warning: Failed to update mirror list, continuing with existing mirrors"
    fi
    
    return 0
}

# Installs all required system packages from the official repositories
install_pacman_packages() {
    local packages=("${PACMAN_PACKAGES[@]}")
    
    log "Installing essential system packages"
    # Use --needed flag to avoid reinstalling packages and only sync once
    if sudo pacman -Syu --needed --noconfirm "${packages[@]}"; then
        log "Core system packages installed successfully"
        return 0
    else
        log "Failed to install required packages"
        return 1
    fi
}

# Configures the tuned daemon for automatic system performance optimization
setup_tuned() {
    log "Setting up system performance tuning"
    if sudo systemctl enable --now tuned && \
       sudo systemctl enable --now tuned-ppd && \
       sudo tuned-adm profile balanced; then
        log "Performance tuning enabled with balanced profile"
        return 0
    else
        log "Failed to configure performance tuning"
        return 1
    fi
}

# Downloads and installs the yay AUR helper for managing community packages
install_yay() {
    log "Installing yay (AUR helper)"
    local yay_dir="$TEMP_DIR/yay-bin"
    
    if git clone https://aur.archlinux.org/yay-bin.git "$yay_dir"; then
        pushd "$yay_dir" > /dev/null || return 1
        if makepkg -si --noconfirm; then
            popd > /dev/null || true
            log "AUR helper installed successfully"
            return 0
        else
            log "Failed to build AUR helper"
            popd > /dev/null || true
            return 1
        fi
    else
        log "Failed to download AUR helper source"
        return 1
    fi
}

# Installs user-defined packages from the Arch User Repository
install_yay_packages() {
    local packages=("${AUR_PACKAGES[@]}")
    log "Installing community packages from AUR"
    # Use run_command for consistent error handling and avoid redundant sync
    if run_command "yay -S --needed --noconfirm ${packages[*]}" \
        "Failed to install AUR packages" \
        "AUR packages installed successfully"; then
        return 0
    else
        return 1
    fi
}

# Configures Flatpak with the Flathub repository for additional applications
setup_flatpak() {
    log "Adding Flatpak repositories"
    run_command "flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo" \
        "Failed to configure Flatpak repository" \
        "Flatpak repository configured"
    return $?
}

# Renames systemd-boot entries to use consistent naming convention
rename_bootloader_entries() {
    log "Renaming boot entries"
    local success=true

    for file in /boot/loader/entries/*linux.conf; do
        if [[ -f "$file" ]]; then
            newname="/boot/loader/entries/arch.conf"
            log "Renaming: $file → $newname"
            if ! sudo mv "$file" "$newname"; then
                log "Failed to rename $file to $newname"
                success=false
            fi
        fi
    done

    for file in /boot/loader/entries/*linux-fallback.conf; do
        if [[ -f "$file" ]]; then
            newname="/boot/loader/entries/arch-fallback.conf"
            log "Renaming: $file → $newname"
            if ! sudo mv "$file" "$newname"; then
                log "Failed to rename $file to $newname"
                success=false
            fi
        fi
    done

    if $success; then
        log "Boot entries renamed successfully"
        return 0
    else
        log "Some boot entries couldn't be renamed"
        return 1
    fi
}

# Adds NVIDIA-specific kernel parameters to bootloader configuration
configure_systemd_boot() {
    log "Adding NVIDIA boot parameters"
    if run_command "sudo sed -i \
        -e '/^options/ s/$/ nvidia-drm.modeset=1 nvidia-drm.fbdev=1/' \
        -e '/^# Created by:/d' \
        -e '/^# Created on:/d' \
        -e '/^title/ s/ (linux)//' /boot/loader/entries/arch.conf" \
        "Failed to configure main boot entry" && \
       run_command "sudo sed -i \
        -e '/^# Created by:/d' \
        -e '/^# Created on:/d' \
        -e '/^title/ s/(linux-fallback)/(fallback)/' /boot/loader/entries/arch-fallback.conf" \
        "Failed to configure fallback boot entry"; then
        log "NVIDIA boot parameters added"
        return 0
    else
        log "Failed to configure bootloader"
        return 1
    fi
}

# Configures early loading of NVIDIA modules in initramfs for better graphics support
configure_nvidia_modules() {
    log "Configuring early NVIDIA module loading"
    if run_command "sudo sed -i \
        -e '/^MODULES=/ s/\\(btrfs\\)/\\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm/' \
        -e '/^HOOKS=/ s/\\<kms\\>[[:space:]]*//' /etc/mkinitcpio.conf" \
        "Failed to update mkinitcpio configuration" && \
       run_command "sudo mkinitcpio -P" \
        "Failed to rebuild initramfs"; then
        log "NVIDIA modules configured and initramfs rebuilt"
        return 0
    else
        log "Failed to configure NVIDIA modules"
        return 1
    fi
}

# Creates pacman hooks for automatic system maintenance and cleanup
setup_pacman_hooks() {
    log "Setting up pacman maintenance hooks"
    if ! sudo mkdir -p /etc/pacman.d/hooks/; then
        log "Failed to create hooks directory"
        return 1
    fi

    if ! sudo tee /etc/pacman.d/hooks/pacman-log-orphans.hook > /dev/null <<'EOF'
[Trigger]
Operation=Remove
Operation=Install
Operation=Upgrade
Type=Package
Target=*

[Action]
Description=Log Orphan Packages
When=PostTransaction
Exec=/bin/bash -c 'pkgs="$(pacman -Qtdq)"; if [[ ! -z "$pkgs" ]]; then echo -e "The following packages are installed but not required (anymore):\n$pkgs\nYou can mark them as explicitly installed with '\''pacman -D --asexplicit <pkg>'\'' or remove them all using '\''pacman -Qtdq | pacman -Rns -'\''"; fi'
EOF
    then
        log "Failed to create orphaned packages hook"
        return 1
    fi

    if ! sudo tee /etc/pacman.d/hooks/pacman-cache.hook > /dev/null <<'EOF'
[Trigger]
Operation=Remove
Operation=Install
Operation=Upgrade
Type=Package
Target=*

[Action]
Description=Keep the last cache and the currently installed.
When=PostTransaction
Exec=/usr/bin/paccache -rvk2
EOF
    then
        log "Failed to create package cache hook"
        return 1
    fi

    log "Pacman hooks installed"
    return 0
}

# Downloads and installs macOS-inspired themes for KDE desktop environment
install_kde_themes() {
    log "Installing WhiteSur desktop themes"
    local kde_theme_dir="$TEMP_DIR/WhiteSur-kde"
    local cursor_theme_dir="$TEMP_DIR/WhiteSur-cursors"

    # Install KDE theme
    try_command "git clone https://github.com/vinceliuice/WhiteSur-kde.git \"$kde_theme_dir\"" \
        "Failed to download KDE theme" || return 1
        
    try_command "cd \"$kde_theme_dir\" && ./install.sh -c dark && cd \"$TEMP_DIR\"" \
        "Failed to install KDE theme" || return 1

    # Install cursor theme
    try_command "git clone https://github.com/vinceliuice/WhiteSur-cursors.git \"$cursor_theme_dir\"" \
        "Failed to download cursor theme" || return 1
        
    try_command "cd \"$cursor_theme_dir\" && ./install.sh && cd \"$TEMP_DIR\"" \
        "Failed to install cursor theme" || return 1

    log "Desktop themes installed"
    return 0
}

# Disables WiFi power saving for better network performance and reliability
disable_wifi_powersave() {
    log "Disabling WiFi power saving"
    
    local config="[connection]\nwifi.powersave = 2"
    try_command "echo -e \"$config\" | sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf > /dev/null" \
        "Failed to create NetworkManager configuration" || return 1
    
    try_command "sudo systemctl restart NetworkManager" "Failed to restart NetworkManager" || return 1
    
    sleep 15
    log "WiFi power saving disabled"
    return 0
}

# Installs Wine and dependencies for running Windows applications
setup_wine() {
    log "Installing Wine for Windows compatibility"
    
    try_command "sudo pacman -S --noconfirm --needed wine-staging winetricks wine-mono" \
        "Failed to install Wine core components" || return 1

    local wine_dependencies=(
        giflib lib32-giflib gnutls lib32-gnutls v4l-utils lib32-v4l-utils 
        libpulse lib32-libpulse alsa-plugins lib32-alsa-plugins 
        alsa-lib lib32-alsa-lib sqlite lib32-sqlite libxcomposite
        lib32-libxcomposite ocl-icd lib32-ocl-icd libva lib32-libva 
        gtk3 lib32-gtk3 gst-plugins-base-libs lib32-gst-plugins-base-libs 
        vulkan-icd-loader lib32-vulkan-icd-loader sdl2-compat lib32-sdl2-compat
    )

    try_command "sudo pacman -S --noconfirm --needed --asdeps ${wine_dependencies[*]}" \
        "Failed to install Wine dependencies" "Wine dependencies installed" || return 1
    
    log "Wine setup complete"
    return 0
}

# Configures GameMode for optimizing system performance during gaming
setup_gamemode() {
    log "Setting up GameMode"
    
    try_command "systemctl --user enable --now gamemoded" "Failed to enable gaming performance service" || return 1

    # Add user to gamemode group if not already a member
    if ! add_user_to_group "gamemode"; then
        log "Failed to configure user permissions for gaming optimizations"
        return 1
    fi
    
    log "GameMode setup complete"
    return 0
}

# Installs and configures QEMU/KVM virtualization with libvirt
setup_virtualization() {
    log "Installing QEMU/KVM virtualization"
    try_command "sudo pacman -S --noconfirm --needed qemu-full qemu-img libvirt virt-install virt-manager virt-viewer edk2-ovmf dnsmasq swtpm guestfs-tools libosinfo" \
        "Failed to install virtualization packages" || return 1

    log "Enabling virtualization services"
    local services=()
    local sockets=()

    for drv in qemu interface network nodedev nwfilter secret storage; do
        services+=("virt${drv}d.service")
        sockets+=("virt${drv}d"{,-ro,-admin}.socket)
    done

    try_command "sudo systemctl enable ${services[*]}" "Failed to enable virtualization services" || return 1
    try_command "sudo systemctl enable ${sockets[*]}" "Failed to enable virtualization sockets" || return 1

    log "Enabling advanced virtualization features"
    try_command "echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/kvm-intel.conf > /dev/null" \
        "Failed to configure nested virtualization" || return 1

    log "Configuring IOMMU for device passthrough"
    if ! modify_config "/boot/loader/entries/arch.conf" '/^options/ s/$/ intel_iommu=on iommu=pt/' ""; then
        log "Failed to configure IOMMU"
        return 1
    fi

    log "Setting up virtualization permissions"
    if ! add_user_to_group "libvirt"; then
        return 1
    fi

    log "Configuring virtualization storage access"
    local acl_cmds=(
        "sudo setfacl -R -b /var/lib/libvirt/images/"
        "sudo setfacl -R -m u:${USER}:rwX /var/lib/libvirt/images/"
        "sudo setfacl -m d:u:${USER}:rwx /var/lib/libvirt/images/"
    )
    
    for cmd in "${acl_cmds[@]}"; do
        try_command "$cmd" "Failed to configure storage permissions" || return 1
    done

    log "Virtualization setup complete"
    return 0
}

# Changes default shell to Zsh and configures plugins and theme
change_default_shell() {
    log "Setting up Zsh with plugins"

    try_command "sudo chsh -s /usr/bin/zsh \"$USER\"" "Failed to change default shell" || return 1

    # Install Oh My Zsh
    log "Installing Oh My Zsh"
    # Download the install script first, then execute it separately to avoid quoting issues
    curl -fsSL -o "$TEMP_DIR/install_ohmyzsh.sh" https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh
    chmod +x "$TEMP_DIR/install_ohmyzsh.sh"
    try_command "$TEMP_DIR/install_ohmyzsh.sh --unattended" \
        "Failed to install Oh My Zsh" || return 1

    # Enable pkgfile-update timer for command-not-found functionality
    log "Enabling pkgfile database update timer"
    if ! run_command "sudo systemctl enable --now pkgfile-update.timer" \
        "Failed to enable pkgfile-update timer" \
        "pkgfile-update timer enabled and started"; then
        log "Warning: pkgfile-update timer could not be enabled, command-not-found may not work properly"
    fi
    
    # Run pkgfile update once to initialize the database
    log "Initializing pkgfile database"
    try_command "sudo pkgfile --update" "Failed to initialize pkgfile database" || return 1

    # Configure zsh with theme and plugins
    local zsh_config="
# Theme
source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme

# Plugins
source /usr/share/doc/pkgfile/command-not-found.zsh
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh
"
    
    append_to_file ~/.zshrc "$zsh_config" || {
        log "Failed to configure shell theme and plugins"
        return 1
    }
    
    log "Zsh setup complete"
    return 0
}

# Sets up DNIe (Spanish National ID card) support
setup_dnie() {
    log "Setting up DNIe (Spanish National ID card) support"
    
    # Install required packages from official repositories
    try_command "sudo pacman -S --noconfirm --needed opensc pcsc-tools ccid" \
        "Failed to install DNIe dependencies" || return 1
    
    # Install DNIe library from AUR
    try_command "yay -S --noconfirm --needed libpkcs11-dnie" \
        "Failed to install DNIe library from AUR" || return 1
    
    # Enable and start the smart card daemon
    try_command "sudo systemctl enable --now pcscd.service" \
        "Failed to enable smart card daemon" \
        "Smart card daemon enabled and started" || return 1
    
    log "DNIe support setup complete"
    log "You can now use your DNIe with compatible applications - Remember to set up your browser"
    return 0
}

# Performs final system updates and removes orphaned packages
cleanup() {
    log "Running final cleanup tasks"
    cd ~ || return 1

    # Update system
    try_command "yay -Syu --noconfirm" "Warning: System update encountered issues, continuing with cleanup" "System fully updated"
    
    # Check and remove orphaned packages
    log "Checking for orphaned packages"
    local pacman_orphans
    pacman_orphans=$(sudo pacman -Qtdq 2>/dev/null)
    
    if [[ -n "$pacman_orphans" ]]; then
        log "Removing orphaned packages"
        try_command "echo \"$pacman_orphans\" | sudo pacman -Rns --noconfirm -" \
            "Warning: Failed to remove some orphaned packages" \
            "Orphaned packages removed"
    else
        log "No orphaned packages found"
    fi

    log "System cleanup complete"
    return 0
}

# Format a step name for display (convert snake_case to Title Case)
format_step_name() {
    local step="$1"
    local display_step="${step//_/ }"
    echo "${display_step^}"
}

# Update progress after a step completes
update_progress() {
    local step="$1"
    LAST_COMPLETED="$step"
    CURRENT_STEP="$step"
    save_progress
}

# Executes a setup step with proper error handling and progress tracking
# Parameters: step name, critical flag (defaults to true)
execute_step() {
    local step=$1
    local critical=${2:-true}
    
    should_execute "$step" || return 0
    
    local display_step
    display_step=$(format_step_name "$step")
    log "Executing step: $display_step"
    
    if "$step"; then
        update_progress "$step"
        return 0
    elif $critical; then
        log "Failed to execute $display_step. Exiting..."
        exit 1
    else
        log "Warning: $display_step failed, but continuing with setup"
        update_progress "$step"
        return 1
    fi
}

# Main function that orchestrates the entire setup process
main() {
    log "Starting Arch Linux post-installation setup"
    
    CURRENT_STEP="start"
    load_progress
    
    # Define steps and their criticality
    local steps=(
        "connect_wifi:true"
        "enable_bluetooth:true"
        "pair_bluetooth_mouse:false"
        "configure_pacman:true"
        "setup_reflector:true"
        "install_pacman_packages:true"
        "setup_tuned:true"
        "install_yay:true"
        "install_yay_packages:true"
        "setup_flatpak:true"
        "rename_bootloader_entries:true"
        "configure_systemd_boot:true"
        "configure_nvidia_modules:true"
        "setup_pacman_hooks:true"
        "install_kde_themes:true"
        "disable_wifi_powersave:true"
        "setup_wine:true"
        "setup_gamemode:true"
        "setup_virtualization:true"
        "setup_dnie:false"
        "change_default_shell:true"
        "cleanup:true"
    )
    
    # Execute each step
    for step_info in "${steps[@]}"; do
        IFS=':' read -r step critical <<< "$step_info"
        execute_step "$step" "$critical"
    done
    
    [[ -f "$PROGRESS_FILE" ]] && rm "$PROGRESS_FILE"
    
    log "Setup complete! 🎉"
    log "A reboot is required to apply all changes"
    
    # Ask if user wants to reboot now
    echo
    read -r -p "Would you like to reboot now? (y/n): " reboot_choice
    if [[ "${reboot_choice,,}" =~ ^(y|yes)$ ]]; then
        log "Rebooting system now..."
        sudo reboot
    else
        log "Please remember to reboot your system later to apply all changes"
    fi
}

main
