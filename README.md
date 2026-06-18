# FaceAuth

Open source face authentication for Linux. Unlock your screen with your face automatically, while keeping your password as the safe fallback.

## Features

- IR sensor support with automatic detection
- Falls back to regular webcam if no IR sensor is available
- Camera activates only when the lockscreen wakes
- Automatic screen unlock on face recognition
- Per-user face registration
- `faceauthctl` command for status, diagnostics, camera testing, and re-enrollment
- Safer runtime token storage under `/run/user/<uid>/faceauth`
- Camera scan timeout and retry cooldown
- Sleep/resume recovery hook
- Safe uninstall script
- Best-effort support across major Linux distributions

## Installation

~~~bash
git clone https://github.com/NEESCHAL-3/FaceAuth.git
cd FaceAuth
bash install.sh
~~~

A reboot is usually not required. After installation, lock your screen and test FaceAuth.

## Supported Systems

- Fedora
- Ubuntu  
- Arch Linux
- Any GNOME based Linux distribution
- KDE Plasma (with SDDM or plasma-login)
- Any Linux distribution using GDM or SDDM as the display manager

## How It Works

FaceAuth runs a lightweight background daemon that monitors for lockscreen events. When the lockscreen wakes, the selected camera activates and scans for your registered face.

Once your face is recognized, FaceAuth writes a short-lived runtime token and sends an unlock signal. The unlock signal targets the screensaver D-Bus interface matching your desktop (`org.gnome.ScreenSaver` on GNOME, `org.freedesktop.ScreenSaver` / `org.kde.screensaver` on KDE Plasma), with `loginctl unlock-sessions` as a fallback. The PAM helper verifies the token and allows the unlock.

If no face is recognized within the configured scan timeout, the camera turns off automatically. If the lockscreen is still awake, FaceAuth waits for a cooldown period and then retries scanning.

For security reasons, FaceAuth may require your password once after a full restart, shutdown, or first boot. After that first password unlock, FaceAuth works normally for lockscreen unlocks and sleep/resume unlocks.

## FaceAuth Control Tool

FaceAuth installs a control command:

~~~bash
faceauthctl
~~~

Useful commands:

~~~bash
faceauthctl status
faceauthctl doctor
faceauthctl logs
faceauthctl list-cameras
faceauthctl test-camera
faceauthctl set-camera <index>
faceauthctl enroll
~~~

## Runtime Behavior

Default behavior:

- Maximum face scan time: 30 seconds
- Retry cooldown while lockscreen is still awake: 20 seconds
- Password remains available as the fallback unlock method
- Reboot, shutdown, or first boot may require password once for security

User configuration is stored at:

~~~bash
~/.faceauth/config.json
~~~

Important config options:

- `ir_camera`: camera index used for face unlock
- `tolerance`: face matching strictness
- `max_scan_seconds`: how long the camera scans before stopping
- `scan_retry_cooldown_seconds`: how long FaceAuth waits before retrying while the lockscreen is still awake
- `desktop`: detected desktop (`gnome` or `kde`), used to pick the right unlock signal
- `display_manager`: detected display manager (`gdm`, `sddm`, ...), used for PAM setup

## Requirements

- Linux with GNOME or KDE Plasma desktop
- GDM (GNOME) or SDDM or plasma-login (KDE Plasma) recommended for automatic PAM setup
- Webcam or IR sensor
- Python 3.8 or higher
- sudo access for installation

## Uninstall

~~~bash
./uninstall.sh
~~~

To remove FaceAuth and delete local FaceAuth user data:

~~~bash
./uninstall.sh --purge
~~~

## Troubleshooting

Check service status:

~~~bash
systemctl status faceauth --no-pager
~~~

Check logs:

~~~bash
journalctl -u faceauth -e --no-pager
~~~

Run diagnostics:

~~~bash
faceauthctl doctor
~~~

If FaceAuth does not unlock immediately:

1. Make sure the selected camera works with `faceauthctl test-camera`
2. Try better lighting
3. Re-register your face with `faceauthctl enroll`
4. Check logs with `faceauthctl logs`
5. Log out and log back in
6. Reboot only as a last fallback

## Security Notes

FaceAuth does not remove your password login. Your password remains the fallback method.

FaceAuth uses a short-lived runtime token stored under `/run/user/<uid>/faceauth`. The token is permission-restricted and consumed after successful use.

For security reasons, password unlock may be required once after reboot, shutdown, or first boot before FaceAuth becomes active for normal lockscreen use.

## Contributing

Pull requests are welcome. For major changes please open an issue first.

## License

MIT
