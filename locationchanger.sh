#!/bin/bash

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 install|uninstall"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo "Error: Root privileges required. Please run with sudo."
   exit 1
fi

INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
LOG_DIR="${LOG_DIR:-/usr/local/var/log}"
PLIST_DIR="${HOME}/Library/LaunchAgents"
SCRIPT_NAME="locationchanger"
LOG_FILE="$LOG_DIR/$SCRIPT_NAME.log"
PLIST_FILE="$PLIST_DIR/$SCRIPT_NAME.plist"
BACKUP_DIR="$LOG_DIR/backups/$SCRIPT_NAME"

if [[ "$1" == "uninstall" ]]; then
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    rm -f "$INSTALL_DIR/$SCRIPT_NAME" "$PLIST_FILE"
    echo "Uninstalled $SCRIPT_NAME"
    exit 0
fi

backup_timestamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR/$backup_timestamp"

for file in "$INSTALL_DIR/$SCRIPT_NAME" "$PLIST_FILE"; do
    if [[ -f "$file" ]]; then
        cp "$file" "$BACKUP_DIR/$backup_timestamp/$(basename "$file")" || {
            echo "Error: Backup failed for $file"
            exit 1
        }
    fi
done

for dir in "$INSTALL_DIR" "$LOG_DIR" "$PLIST_DIR"; do
    mkdir -p "$dir" || { 
        echo "Error: Failed to create directory: $dir"
        exit 1
    }
    chmod 755 "$dir"
done

cat << 'EOF' > "$INSTALL_DIR/$SCRIPT_NAME"
set -euo pipefail

VERSION="1.0.0"

readonly MAX_RETRIES=3
readonly RETRY_DELAY=2
readonly LOG_MAX_SIZE=$((10 * 1024 * 1024)) 
log() {
    local level="$1"
    shift
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    
        if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE") -gt $LOG_MAX_SIZE ]]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
    fi
    
    echo "$message" >> "$LOG_FILE"
}

cleanup() {
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Script failed with error code $?"
    fi
}
trap cleanup EXIT

validate_ssid() {
    local ssid="$1"
    if [[ "$ssid" =~ ^[[:alnum:][-._[:space:]\(\)@]{1,32}$ ]]; then
        return 0
    fi
    return 1
}

get_active_interface() {
    local retry=0
    while ((retry < MAX_RETRIES)); do
        for interface in en0 en1 en2 wifi0; do
            if networksetup -getairportnetwork "$interface" &>/dev/null; then
                echo "$interface"
                return 0
            fi
        done
        ((retry++))
        sleep "$RETRY_DELAY"
    done
    return 1
}

validate_location() {
    local location="$1"
    networksetup -listlocations | grep -q "^${location}$"
}

log "INFO" "Starting $SCRIPT_NAME v$VERSION"

INTERFACE=$(get_active_interface)
if [[ -z "$INTERFACE" ]]; then
    log "ERROR" "No active wireless interface found after $MAX_RETRIES retries"
    exit 1
fi
log "INFO" "Using interface: $INTERFACE"

SSID=$(timeout 5 networksetup -getairportnetwork "$INTERFACE" | awk -F': ' '{print $2}')
if [[ -z "$SSID" ]]; then
    log "ERROR" "Failed to get SSID from interface $INTERFACE"
    exit 1
fi

if ! validate_ssid "$SSID"; then
    log "ERROR" "Invalid SSID format: $SSID"
    exit 1
fi
log "INFO" "Current SSID: $SSID"

LOCATIONS_CONFIG="$HOME/.config/locationchanger/locations.conf"
declare -A locations

if [[ -f "$LOCATIONS_CONFIG" ]]; then
    while IFS='=' read -r ssid location; do
        locations["$ssid"]="$location"
    done < "$LOCATIONS_CONFIG"
else
    locations=(
        ["HomeSSID"]="Home"
        ["WorkSSID"]="Work"
    )
fi

LOCATION="${DEFAULT_LOCATION:-Automatic}"

for key in "${!locations[@]}"; do
    if [[ "$SSID" == "$key" ]]; then
        LOCATION=${locations[$key]}
        break
    fi
done

if ! validate_location "$LOCATION"; then
    log "ERROR" "Location '$LOCATION' does not exist"
    exit 1
fi

current_location=$(networksetup -getcurrentlocation)
if [[ "$current_location" != "$LOCATION" ]]; then
    retry=0
    while ((retry < MAX_RETRIES)); do
        if networksetup -switchtolocation "$LOCATION"; then
            log "INFO" "Network location changed to $LOCATION"
            break
        fi
        ((retry++))
        log "WARN" "Failed to switch location, attempt $retry of $MAX_RETRIES"
        sleep "$RETRY_DELAY"
    done
    if ((retry >= MAX_RETRIES)); then
        log "ERROR" "Failed to switch to location: $LOCATION after $MAX_RETRIES attempts"
        exit 1
    fi
fi
EOF

chmod 755 "$INSTALL_DIR/$SCRIPT_NAME"

cat << EOF > "$PLIST_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$SCRIPT_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/$SCRIPT_NAME</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist</string>
        <string>/Library/Preferences/SystemConfiguration/com.apple.wifi.message-tracer.plist</string>
        <string>/Library/Preferences/com.apple.wifi.known-networks.plist</string>
    </array>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

chown root:wheel "$INSTALL_DIR/$SCRIPT_NAME"
chmod 644 "$PLIST_FILE"
chmod 755 "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

launchctl unload "$PLIST_FILE" 2>/dev/null || true
if ! launchctl load -w "$PLIST_FILE"; then
    echo "Error: Failed to load $SCRIPT_NAME service"
    exit 1
fi

echo "$SCRIPT_NAME v1.0.0 installed and activated successfully"
log "INFO" "Installation completed successfully"
