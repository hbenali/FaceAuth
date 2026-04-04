# FaceAuth

Open source face authentication for Linux. Unlock your screen with your face automatically.

## Features

- IR sensor support with automatic detection
- Falls back to regular webcam if no IR sensor
- Camera activates only when screen is locked
- Automatic screen unlock on face recognition
- Per user face registration
- Works across major Linux distributions

## Installation
```bash
curl -sSL https://raw.githubusercontent.com/NEESCHAL-3/FaceAuth/main/install.sh | bash
```

## Supported Systems

- Fedora
- Ubuntu  
- Arch Linux
- Any GNOME based Linux distribution

## How It Works

FaceAuth runs a lightweight background daemon that monitors for screen lock events. When the screen locks, the camera activates and scans for your face. Once recognized, the screen unlocks automatically. The camera turns off immediately after.

## Requirements

- Linux with GNOME desktop
- Webcam or IR sensor
- Python 3.8 or higher
- sudo access for installation

## Uninstall
```bash
sudo systemctl stop faceauth
sudo systemctl disable faceauth
sudo rm /usr/local/bin/faceauth_daemon
sudo rm /usr/local/bin/faceauth
sudo rm /etc/systemd/system/faceauth.service
rm -rf ~/.faceauth
```

## Contributing

Pull requests are welcome. For major changes please open an issue first.

## License

MIT
