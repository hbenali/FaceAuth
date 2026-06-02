#!/bin/bash

echo "========================================"
echo "   FaceAuth Uninstaller"
echo "========================================"

USERNAME=$(whoami)
FACEAUTH_HOME="/home/$USERNAME/.faceauth"
PAM_LINE="auth sufficient pam_exec.so quiet /usr/local/bin/faceauth"

log() {
    echo ""
    echo "==> $1"
}

warn() {
    echo "WARN: $1"
}

log "Stopping FaceAuth service"
sudo systemctl stop faceauth 2>/dev/null || true
sudo systemctl disable faceauth 2>/dev/null || true

log "Removing systemd service"
sudo rm -f /etc/systemd/system/faceauth.service
sudo systemctl daemon-reload
sudo systemctl reset-failed faceauth 2>/dev/null || true

log "Removing FaceAuth PAM line"

PAM_FILES=(
    "/etc/pam.d/gdm-password"
    "/etc/pam.d/sddm"
    "/etc/pam.d/lightdm"
)

for pam_file in "${PAM_FILES[@]}"; do
    if [ -f "$pam_file" ]; then
        if sudo grep -Fxq "$PAM_LINE" "$pam_file"; then
            backup="${pam_file}.faceauth-uninstall-backup-$(date +%Y%m%d-%H%M%S)"
            sudo cp "$pam_file" "$backup"
            sudo sed -i "\|$PAM_LINE|d" "$pam_file"
            echo "Removed FaceAuth PAM line from $pam_file"
            echo "Backup created: $backup"
        fi
    fi
done

log "Removing FaceAuth binaries"
sudo rm -f /usr/local/bin/faceauth
sudo rm -f /usr/local/bin/faceauth_daemon

log "Removing runtime token"
rm -rf "/run/user/$(id -u)/faceauth" 2>/dev/null || true

if [ "$1" = "--purge" ]; then
    log "Purging user FaceAuth data"
    rm -rf "$FACEAUTH_HOME"
else
    echo ""
    echo "User FaceAuth data kept at: $FACEAUTH_HOME"
    echo "Run './uninstall.sh --purge' to remove registered face/config too."
fi

echo ""
echo "========================================"
echo "FaceAuth uninstalled successfully."
echo "========================================"
