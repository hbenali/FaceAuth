#!/bin/bash

echo "========================================"
echo "   FaceAuth Universal Installer"
echo "========================================"

USERNAME=$(whoami)
USER_ID=$(id -u)
echo "Installing for user: $USERNAME (UID: $USER_ID)"

# Helper functions
log() {
    echo ""
    echo "==> $1"
}

warn() {
    echo "WARN: $1"
}

die() {
    echo ""
    echo "ERROR: $1"
    echo "FaceAuth install stopped safely before making unsafe changes."
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

TOTAL_STEPS=11
CURRENT_STEP=0

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    echo "[$CURRENT_STEP/$TOTAL_STEPS] $1"
}

# Install dependencies
step "Installing system dependencies"

PIP_ARGS=()

install_python_packages() {
    step "Installing Python face recognition packages"

    if python3 -m pip install --help 2>/dev/null | grep -q -- "--break-system-packages"; then
        PIP_ARGS+=(--break-system-packages)
    fi

    # Keep setuptools below 81 because face_recognition_models still depends on pkg_resources.
    sudo python3 -m pip install --upgrade "pip" "setuptools<81" "wheel" "${PIP_ARGS[@]}" || \
        warn "Could not prepare pip/setuptools/wheel. Continuing with existing versions."

    echo "Downloading/installing face recognition models from GitHub if not already installed..."
    echo "This may show as: Cloning face_recognition_models to a temporary /tmp/pip-req-build-* folder."

    if ! sudo python3 -m pip install \
        "setuptools<81" \
        face_recognition \
        git+https://github.com/ageitgey/face_recognition_models \
        opencv-python \
        "${PIP_ARGS[@]}"; then

        warn "Full pip install failed. Trying fallback without opencv-python because distro OpenCV may already be installed."

        sudo python3 -m pip install \
            "setuptools<81" \
            face_recognition \
            git+https://github.com/ageitgey/face_recognition_models \
            "${PIP_ARGS[@]}" || die "Python face recognition packages could not be installed."
    fi
}

install_fedora_deps() {
    echo "Fedora/RHEL-based system detected"

    # Fedora 41+ may use dnf5. Old "dnf groupinstall" can fail there.
    if ! sudo dnf group install -y "Development Tools" "C Development Tools and Libraries"; then
        warn "dnf group install failed. Trying older dnf groupinstall syntax."

        sudo dnf groupinstall -y "Development Tools" "C Development Tools and Libraries" || \
            warn "Development group install failed or is unavailable. Continuing with direct packages."
    fi

    # Required build/runtime packages. Keep this small; pip handles Python face packages.
    sudo dnf install -y \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make cmake git \
        pam-devel \
        python3-opencv \
        blas-devel lapack-devel \
        libX11-devel || die "Required Fedora dependencies could not be installed."

    # Optional distro dlib packages. Some Fedora versions do not provide these names.
    # If unavailable, pip will build/install dlib through face_recognition.
    sudo dnf install -y --skip-unavailable \
        dlib dlib-devel python3-dlib || \
        warn "Fedora dlib packages unavailable. Pip will try to install/build dlib."
}


install_debian_deps() {
    echo "Debian/Ubuntu-based system detected"

    sudo apt update || die "apt update failed."

    if ! sudo apt install -y \
        python3 python3-pip python3-dev \
        build-essential cmake git \
        libpam0g-dev \
        libdlib-dev \
        libopencv-dev python3-opencv \
        libblas-dev liblapack-dev \
        libx11-dev; then

        warn "Some Debian/Ubuntu package names were unavailable. Trying smaller fallback package set."

        sudo apt install -y \
            python3 python3-pip python3-dev \
            build-essential cmake git \
            libpam0g-dev \
            libopencv-dev python3-opencv \
            libblas-dev liblapack-dev \
            libx11-dev || die "Required Debian/Ubuntu dependencies could not be installed."
    fi
}

install_arch_deps() {
    echo "Arch-based system detected"

    if ! sudo pacman -S --noconfirm --needed \
        python python-pip \
        base-devel cmake git \
        pam \
        dlib opencv \
        blas lapack \
        libx11; then

        warn "Some Arch packages were unavailable. Trying minimum fallback package set."

        sudo pacman -S --noconfirm --needed \
            python python-pip \
            base-devel cmake git \
            pam \
            opencv \
            blas lapack \
            libx11 || die "Required Arch dependencies could not be installed."
    fi
}

if command_exists dnf; then
    install_fedora_deps
elif command_exists apt; then
    install_debian_deps
elif command_exists pacman; then
    install_arch_deps
else
    die "Unsupported distro. Supported package managers for now: dnf, apt, pacman."
fi

install_python_packages

step "Checking FaceAuth Python dependencies"
python3 - <<'PYDEP'
import sys

checks = [
    ("pkg_resources", "pkg_resources"),
    ("cv2", "cv2"),
    ("dlib", "dlib"),
    ("face_recognition_models", "face_recognition_models"),
    ("face_recognition", "face_recognition"),
]

failed = []

for label, module in checks:
    try:
        __import__(module)
        print(f"OK: {label}")
    except BaseException as e:
        print(f"FAILED: {label}: {e}")
        failed.append(label)

if failed:
    print("")
    print("Missing or broken Python modules:", ", ".join(failed))
    sys.exit(1)

print("All Python dependencies are ready.")
PYDEP

if [ $? -ne 0 ]; then
    die "Dependency check failed. Camera, systemd, and PAM were not touched."
fi

echo "Dependencies ready!"

# Detect desktop environment
step "Detecting desktop environment"
if [ "$XDG_CURRENT_DESKTOP" = "GNOME" ]; then
    DE="gnome"
    echo "GNOME detected"
elif [ "$XDG_CURRENT_DESKTOP" = "KDE" ]; then
    DE="kde"
    echo "KDE detected"
else
    DE="gnome"
    echo "Defaulting to GNOME"
fi

# Detect camera - prefer IR-like camera, fallback to RGB
step "Detecting cameras"

CAMERA_LOG="/tmp/faceauth_camera_detect.log"

CAMERA_INFO=$(python3 - <<'PYCAM' 2>"$CAMERA_LOG"
import cv2
import numpy as np
import sys

valid_cameras = []

for i in range(10):
    cap = cv2.VideoCapture(i)

    if not cap.isOpened():
        cap.release()
        continue

    frame = None

    for _ in range(8):
        ret, f = cap.read()
        if ret and f is not None and f.size > 0 and float(f.mean()) > 1:
            frame = f
            break

    cap.release()

    if frame is None:
        continue

    if len(frame.shape) == 2:
        diff = 0
        brightness = float(frame.mean())
    else:
        b, g, r = cv2.split(frame)
        diff = int(np.mean(np.abs(b.astype(int) - r.astype(int))))
        brightness = float(frame.mean())

    valid_cameras.append((i, diff, brightness))

if not valid_cameras:
    print("NO_CAMERA")
    sys.exit(2)

selected = None
kind = "rgb"

# IR/depth cameras often appear grayscale or near-grayscale.
for idx, diff, brightness in valid_cameras:
    if diff <= 2:
        selected = (idx, diff, brightness)
        kind = "ir-like"
        break

# Fallback to normal RGB camera.
if selected is None:
    selected = valid_cameras[0]
    kind = "rgb"

idx, diff, brightness = selected
print(f"{idx}:{kind}:{diff}:{brightness:.2f}")
PYCAM
)

CAMERA_STATUS=$?

if [ "$CAMERA_STATUS" -ne 0 ] || [ -z "$CAMERA_INFO" ] || [ "$CAMERA_INFO" = "NO_CAMERA" ]; then
    echo ""
    echo "Camera detection log:"
    if [ -s "$CAMERA_LOG" ]; then
        cat "$CAMERA_LOG"
    else
        echo "No extra camera error output."
    fi
    die "No usable camera found. Connect/enable a webcam and run the installer again."
fi

IR_INDEX=$(echo "$CAMERA_INFO" | cut -d':' -f1)
CAMERA_KIND=$(echo "$CAMERA_INFO" | cut -d':' -f2)
CAMERA_DIFF=$(echo "$CAMERA_INFO" | cut -d':' -f3)
CAMERA_BRIGHTNESS=$(echo "$CAMERA_INFO" | cut -d':' -f4)

if ! [[ "$IR_INDEX" =~ ^[0-9]+$ ]]; then
    die "Camera detection returned an invalid camera index: $IR_INDEX"
fi

echo "Selected $CAMERA_KIND camera at index: $IR_INDEX"
echo "Camera color-diff: $CAMERA_DIFF, brightness: $CAMERA_BRIGHTNESS"

# Create faceauth directory
FACEAUTH_HOME="/home/$USERNAME/.faceauth"
mkdir -p "$FACEAUTH_HOME"
chmod 700 "$FACEAUTH_HOME"

# Save config
export FACEAUTH_HOME IR_INDEX DE
python3 - <<'PYCFG'
import json
import os

config = {
    "ir_camera": int(os.environ["IR_INDEX"]),
    "rgb_camera": 0,
    "tolerance": 0.6,
    "max_attempts": 50,
    "desktop": os.environ["DE"],
}

config_path = os.path.join(os.environ["FACEAUTH_HOME"], "config.json")

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)

print("Config saved!")
PYCFG

# Capture face
step "Capturing registered face"
echo "========================================"
echo "FACE REGISTRATION"
echo "Look directly at the selected camera."
echo "Capturing in 3 seconds..."
echo "========================================"

CAPTURE_LOG="/tmp/faceauth_capture.log"
FACE_IMAGE="$FACEAUTH_HOME/my_face.jpg"

export IR_INDEX FACE_IMAGE

python3 - <<'PYCAP' 2>"$CAPTURE_LOG"
import cv2
import os
import sys
import time

camera_index = int(os.environ["IR_INDEX"])
face_image = os.environ["FACE_IMAGE"]

cap = cv2.VideoCapture(camera_index)

if not cap.isOpened():
    print(f"Selected camera index {camera_index} failed to open.", file=sys.stderr)
    sys.exit(1)

time.sleep(3)

for _ in range(15):
    cap.read()

frame = None

for _ in range(20):
    ret, f = cap.read()
    if ret and f is not None and f.size > 0 and float(f.mean()) > 1:
        frame = f
        break
    time.sleep(0.1)

cap.release()

if frame is None:
    print("Could not capture a valid camera frame.", file=sys.stderr)
    sys.exit(1)

if not cv2.imwrite(face_image, frame):
    print(f"Failed to write face image to {face_image}", file=sys.stderr)
    sys.exit(1)

print("Face image captured.")
PYCAP

if [ $? -ne 0 ] || [ ! -s "$FACE_IMAGE" ]; then
    echo ""
    echo "Face capture log:"
    if [ -s "$CAPTURE_LOG" ]; then
        cat "$CAPTURE_LOG"
    else
        echo "No extra capture error output."
    fi
    die "Face capture failed. Systemd and PAM were not touched."
fi

chmod 600 "$FACE_IMAGE"
echo "Face image saved: $FACE_IMAGE"

# Verify face
step "Verifying registered face"

VERIFY_LOG="/tmp/faceauth_verify.log"
export FACE_IMAGE

python3 - <<'PYVERIFY' 2>"$VERIFY_LOG"
import os
import sys
import face_recognition

face_image = os.environ["FACE_IMAGE"]

try:
    image = face_recognition.load_image_file(face_image)
    encodings = face_recognition.face_encodings(image)
except Exception as e:
    print(f"Face verification error: {e}", file=sys.stderr)
    sys.exit(1)

if not encodings:
    print("No face encoding was created from the captured image.", file=sys.stderr)
    sys.exit(2)

if len(encodings) > 1:
    print(f"WARNING: {len(encodings)} faces detected. Using the first face only.")

print(f"Face verified. Encodings found: {len(encodings)}")
PYVERIFY

if [ $? -ne 0 ]; then
    echo ""
    echo "Face verification log:"
    if [ -s "$VERIFY_LOG" ]; then
        cat "$VERIFY_LOG"
    else
        echo "No extra verification error output."
    fi
    die "Face verification failed. Try better lighting and make sure only your face is visible."
fi

# Write daemon
step "Installing FaceAuth daemon"
sudo tee /usr/local/bin/faceauth_daemon > /dev/null << 'DAEMON_EOF'
#!/usr/bin/env python3
import face_recognition
import cv2
import os
import json
import time
import signal
import sys
import subprocess
import threading

def get_token_file():
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")

    if runtime_dir:
        token_dir = os.path.join(runtime_dir, "faceauth")
    else:
        token_dir = f"/run/user/{os.getuid()}/faceauth"

    os.makedirs(token_dir, mode=0o700, exist_ok=True)
    return os.path.join(token_dir, "token")

def load_config(username):
    config_path = f"/home/{username}/.faceauth/config.json"
    face_path = f"/home/{username}/.faceauth/my_face.jpg"
    try:
        with open(config_path) as f:
            config = json.load(f)
        ir_index = config["ir_camera"]
        tolerance = config["tolerance"]
    except:
        ir_index = 0
        tolerance = 0.6
    image = face_recognition.load_image_file(face_path)
    encodings = face_recognition.face_encodings(image)
    if not encodings:
        sys.exit(1)
    return ir_index, tolerance, encodings[0]

def write_token(username):
    token_file = get_token_file()

    fd = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)

    with os.fdopen(fd, "w") as f:
        f.write(f"{username}:{time.time()}")

    os.chmod(token_file, 0o600)

def unlock_screen():
    try:
        subprocess.run(
            ["gdbus", "call", "--session",
             "--dest", "org.gnome.ScreenSaver",
             "--object-path", "/org/gnome/ScreenSaver",
             "--method", "org.gnome.ScreenSaver.SetActive",
             "false"],
            capture_output=True, text=True
        )
        print("Unlock signal sent!")
    except Exception as e:
        print(f"Unlock error: {e}")

def face_recognition_loop(username, ir_index, tolerance, my_encoding, stop_event):
    print("Camera activated - looking for face")
    video = cv2.VideoCapture(ir_index)
    for _ in range(10):
        video.read()
    match_count = 0
    while not stop_event.is_set():
        ret, frame = video.read()
        if not ret:
            time.sleep(0.1)
            continue
        rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        face_locations = face_recognition.face_locations(rgb_frame)
        face_encodings = face_recognition.face_encodings(rgb_frame, face_locations)
        for encoding in face_encodings:
            match = face_recognition.compare_faces([my_encoding], encoding, tolerance=tolerance)
            if match[0]:
                match_count += 1
                if match_count >= 3:
                    print("Face recognized! Unlocking...")
                    write_token(username)
                    unlock_screen()
                    match_count = 0
            else:
                match_count = max(0, match_count - 1)
        time.sleep(0.1)
    video.release()
    print("Camera deactivated")

def run_daemon(username):
    print(f"FaceAuth daemon starting for {username}")
    ir_index, tolerance, my_encoding = load_config(username)
    stop_event = None
    face_thread = None
    lock_time = None
    is_locked_state = False

    proc = subprocess.Popen(
        ["gdbus", "monitor", "--system",
         "--dest", "org.freedesktop.login1"],
        stdout=subprocess.PIPE,
        text=True
    )

    print("Watching for real lockscreen events...")

    def handle_exit(sig, frame):
        if stop_event:
            stop_event.set()
        proc.terminate()
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_exit)
    signal.signal(signal.SIGINT, handle_exit)

    for line in proc.stdout:
        if "'LockedHint': <true>" in line:
            is_locked_state = True
            lock_time = time.time()
            print("Lock signal received - monitoring...")

        elif "'IdleHint': <false>" in line and is_locked_state:
            elapsed = time.time() - lock_time if lock_time else 0
            print(f"Wake signal after {elapsed:.1f}s")
            if elapsed < 1:
                print("Quick wake - just screen dim, ignoring")
                is_locked_state = False
                lock_time = None
            else:
                if stop_event is None:
                    print("Real lockscreen - starting camera!")
                    stop_event = threading.Event()
                    face_thread = threading.Thread(
                        target=face_recognition_loop,
                        args=(username, ir_index, tolerance, my_encoding, stop_event)
                    )
                    face_thread.daemon = True
                    face_thread.start()

        elif "'LockedHint': <false>" in line or "Session.Unlock" in line:
            print("Screen UNLOCKED - stopping camera")
            is_locked_state = False
            lock_time = None
            if stop_event:
                stop_event.set()
                stop_event = None

if __name__ == "__main__":
    username = sys.argv[1] if len(sys.argv) > 1 else "FACEAUTH_USER"
    run_daemon(username)
DAEMON_EOF

sudo chmod +x /usr/local/bin/faceauth_daemon
sudo sed -i "s/FACEAUTH_USER/$USERNAME/g" /usr/local/bin/faceauth_daemon

# Write PAM script
sudo tee /usr/local/bin/faceauth > /dev/null << 'PAM_EOF'
#!/usr/bin/env python3
import os
import pwd
import sys
import time

TOKEN_VALIDITY = 10

def get_user_uid(username):
    return pwd.getpwnam(username).pw_uid

def get_token_file(username):
    uid = get_user_uid(username)
    return os.path.join("/run/user", str(uid), "faceauth", "token")

def check_token(username):
    try:
        if not username:
            return False

        expected_uid = get_user_uid(username)
        token_file = get_token_file(username)

        if not os.path.exists(token_file):
            return False

        st = os.stat(token_file)

        if st.st_uid != expected_uid:
            return False

        if st.st_mode & 0o077:
            return False

        with open(token_file, "r") as f:
            content = f.read().strip()
        token_user, timestamp = content.split(":")
        timestamp = float(timestamp)
        age = time.time() - timestamp
        if token_user == username and age < TOKEN_VALIDITY:
            os.remove(token_file)
            return True
        return False
    except:
        return False

if __name__ == "__main__":
    username = os.environ.get("PAM_USER", os.environ.get("USER", ""))
    result = check_token(username)
    sys.exit(0 if result else 1)
PAM_EOF

sudo chmod +x /usr/local/bin/faceauth

# Install systemd service
step "Installing systemd service"
sudo tee /etc/systemd/system/faceauth.service > /dev/null << EOF
[Unit]
Description=FaceAuth Face Recognition Daemon
After=display-manager.service graphical-session.target
Wants=display-manager.service

[Service]
Type=simple
User=$USERNAME
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_ID/bus
Environment=XDG_RUNTIME_DIR=/run/user/$USER_ID
Environment=PYTHONUNBUFFERED=1
ExecStartPre=/bin/bash -c 'until [ -S /run/user/$USER_ID/bus ]; do sleep 0.5; done; sleep 5'
ExecStart=/usr/bin/python3 -u /usr/local/bin/faceauth_daemon $USERNAME
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
EOF

# Setup PAM
step "Setting up PAM"

PAM_FILE=""
PAM_CHANGED=0

if [ "$DE" = "gnome" ]; then
    PAM_FILE="/etc/pam.d/gdm-password"
else
    warn "Automatic PAM setup currently supports GNOME/GDM only."
    warn "Skipping PAM modification for this desktop environment."
fi

if [ -n "$PAM_FILE" ]; then
    if [ ! -f "$PAM_FILE" ]; then
        die "PAM file not found: $PAM_FILE"
    fi

    PAM_BACKUP="${PAM_FILE}.faceauth-backup-$(date +%Y%m%d-%H%M%S)"
    sudo cp "$PAM_FILE" "$PAM_BACKUP"
    echo "PAM backup created: $PAM_BACKUP"

    PAM_LINE="auth sufficient pam_exec.so quiet /usr/local/bin/faceauth"

    if sudo grep -Fxq "$PAM_LINE" "$PAM_FILE"; then
        echo "PAM already configured."
    else
        sudo sed -i "1i$PAM_LINE" "$PAM_FILE"

        if sudo grep -Fxq "$PAM_LINE" "$PAM_FILE"; then
            PAM_CHANGED=1
            echo "PAM configured successfully."
        else
            sudo cp "$PAM_BACKUP" "$PAM_FILE"
            die "PAM modification failed. Backup restored."
        fi
    fi
fi

# Enable and start service only after PAM setup has succeeded/skipped safely
step "Starting FaceAuth service"

if ! sudo systemctl daemon-reload; then
    if [ "$PAM_CHANGED" = "1" ] && [ -n "$PAM_BACKUP" ]; then
        sudo cp "$PAM_BACKUP" "$PAM_FILE"
    fi
    die "systemd daemon-reload failed."
fi

if ! sudo systemctl enable faceauth; then
    if [ "$PAM_CHANGED" = "1" ] && [ -n "$PAM_BACKUP" ]; then
        sudo cp "$PAM_BACKUP" "$PAM_FILE"
    fi
    die "Could not enable FaceAuth systemd service."
fi

if ! sudo systemctl restart faceauth; then
    if [ "$PAM_CHANGED" = "1" ] && [ -n "$PAM_BACKUP" ]; then
        sudo cp "$PAM_BACKUP" "$PAM_FILE"
    fi
    die "Could not start FaceAuth systemd service. PAM backup restored if FaceAuth changed it."
fi

sleep 2

if sudo systemctl is-active --quiet faceauth; then
    echo "FaceAuth service is active."
else
    warn "FaceAuth service is not active yet."
    warn "Check logs with: journalctl -u faceauth -e --no-pager"
fi

echo ""
echo "========================================"
echo "FaceAuth installed successfully!"
echo "FaceAuth service is started now."
echo "Lock your screen to test face unlock."
echo ""
echo "If it does not work immediately:"
echo "  1. Check logs: journalctl -u faceauth -e --no-pager"
echo "  2. Log out and log back in"
echo "  3. Reboot only as a last fallback"
echo "========================================"
