#!/bin/bash

echo "========================================"
echo "   FaceAuth Universal Installer"
echo "========================================"

USERNAME=$(whoami)
USER_ID=$(id -u)
FORCE_ENROLL=0

if [ "$1" = "--force-enroll" ] || [ "$1" = "--re-enroll" ]; then
    FORCE_ENROLL=1
fi

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

TOTAL_STEPS=12
CURRENT_STEP=0

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    echo "[$CURRENT_STEP/$TOTAL_STEPS] $1"
}

RUN_LOG_DIR="/tmp/faceauth-install-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_LOG_DIR"

note() {
    echo "NOTE: $1"
}

run_capture() {
    local label="$1"
    shift

    local safe_label
    safe_label=$(echo "$label" | tr -c 'A-Za-z0-9_.-' '_')
    local logfile="$RUN_LOG_DIR/${safe_label}.log"

    if [ "${FACEAUTH_VERBOSE:-0}" = "1" ]; then
        "$@"
    else
        "$@" >"$logfile" 2>&1
    fi

    return $?
}

run_required() {
    local label="$1"
    shift

    local safe_label
    safe_label=$(echo "$label" | tr -c 'A-Za-z0-9_.-' '_')
    local logfile="$RUN_LOG_DIR/${safe_label}.log"

    if run_capture "$label" "$@"; then
        return 0
    fi

    echo ""
    echo "Command failed: $*"
    echo "Log file: $logfile"

    if [ -s "$logfile" ]; then
        echo ""
        echo "Last lines from log:"
        tail -80 "$logfile"
    fi

    return 1
}

run_optional() {
    local label="$1"
    local message="$2"
    shift 2

    local safe_label
    safe_label=$(echo "$label" | tr -c 'A-Za-z0-9_.-' '_')
    local logfile="$RUN_LOG_DIR/${safe_label}.log"

    if run_capture "$label" "$@"; then
        return 0
    fi

    note "$message"
    note "Details saved to: $logfile"
    return 0
}

# Install dependencies
step "Installing system dependencies"

PIP_ARGS=()

install_python_packages() {
    step "Installing Python face recognition packages"

    PIP_ARGS=()

    if python3 -m pip install --help 2>/dev/null | grep -q -- "--break-system-packages"; then
        PIP_ARGS+=(--break-system-packages)
    fi

    if python3 -m pip install --help 2>/dev/null | grep -q -- "--root-user-action"; then
        PIP_ARGS+=(--root-user-action=ignore)
    fi

    note "Preparing Python packaging tools"
    run_optional \
        "pip-tools" \
        "Could not upgrade pip/setuptools/wheel. Continuing with existing versions." \
        sudo python3 -m pip install --upgrade "pip" "setuptools<81" "wheel" "${PIP_ARGS[@]}"

    note "Installing FaceAuth Python packages"
    note "Full pip logs are saved in: $RUN_LOG_DIR"

    if ! run_capture "pip-faceauth-full" \
        sudo python3 -m pip install \
            "setuptools<81" \
            face_recognition \
            git+https://github.com/ageitgey/face_recognition_models \
            opencv-python \
            "${PIP_ARGS[@]}"; then

        note "Full pip install failed. Trying fallback without opencv-python because distro OpenCV may already be installed."

        run_required \
            "pip-faceauth-fallback" \
            sudo python3 -m pip install \
                "setuptools<81" \
                face_recognition \
                git+https://github.com/ageitgey/face_recognition_models \
                "${PIP_ARGS[@]}" || die "Python face recognition packages could not be installed."
    fi
}


install_fedora_deps() {
    echo "Fedora/RHEL-based system detected"
    note "Using direct package install. Skipping optional development groups to avoid dnf/dnf5 group-name differences."

    run_required \
        "dnf-required" \
        sudo dnf install -y \
            python3 python3-pip python3-devel \
            gcc gcc-c++ make cmake git \
            pam-devel \
            python3-opencv \
            blas-devel lapack-devel \
            libX11-devel || die "Required Fedora dependencies could not be installed."

    note "Skipping optional Fedora dlib RPM packages. Pip/face_recognition will provide dlib if needed."
}


install_debian_deps() {
    echo "Debian/Ubuntu-based system detected"

    run_required "apt-update" sudo apt update || die "apt update failed."

    if ! run_capture \
        "apt-full" \
        sudo apt install -y \
            python3 python3-pip python3-dev \
            build-essential cmake git \
            libpam0g-dev \
            libdlib-dev \
            libopencv-dev python3-opencv \
            libblas-dev liblapack-dev \
            libx11-dev; then

        note "Some Debian/Ubuntu package names were unavailable. Trying smaller fallback package set."

        run_required \
            "apt-fallback" \
            sudo apt install -y \
                python3 python3-pip python3-dev \
                build-essential cmake git \
                libpam0g-dev \
                python3-opencv \
                libblas-dev liblapack-dev \
                libx11-dev || die "Required Debian/Ubuntu dependencies could not be installed."
    fi
}


install_arch_deps() {
    echo "Arch-based system detected"

    if ! run_capture \
        "pacman-full" \
        sudo pacman -S --noconfirm --needed \
            python python-pip \
            base-devel cmake git \
            pam \
            dlib opencv \
            blas lapack \
            libx11; then

        note "Some Arch packages were unavailable. Trying minimum fallback package set."

        run_required \
            "pacman-fallback" \
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
import warnings

warnings.filterwarnings(
    "ignore",
    message="pkg_resources is deprecated as an API.*",
    category=UserWarning,
)

checks = [
    ("setuptools compatibility", "pkg_resources"),
    ("OpenCV", "cv2"),
    ("dlib", "dlib"),
    ("face recognition models", "face_recognition_models"),
    ("face recognition", "face_recognition"),
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
export FACEAUTH_HOME IR_INDEX DE FORCE_ENROLL
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
step "Checking face enrollment"

CAPTURE_LOG="/tmp/faceauth_capture.log"
FACE_IMAGE="$FACEAUTH_HOME/my_face.jpg"

export IR_INDEX FACE_IMAGE FORCE_ENROLL

SKIP_CAPTURE=0

if [ "$FORCE_ENROLL" != "1" ] && [ -s "$FACE_IMAGE" ]; then
    log "Existing face enrollment found"

    if python3 - <<'PYCHECK'
import os
import sys
import warnings

warnings.filterwarnings(
    "ignore",
    message="pkg_resources is deprecated as an API.*",
    category=UserWarning,
)

import face_recognition

face_image = os.environ["FACE_IMAGE"]

try:
    image = face_recognition.load_image_file(face_image)
    encodings = face_recognition.face_encodings(image)
except Exception as e:
    print(f"Existing face check failed: {e}")
    sys.exit(1)

if not encodings:
    print("Existing face image has no usable face encoding.")
    sys.exit(1)

print(f"Keeping existing face enrollment. Encodings found: {len(encodings)}")
PYCHECK
    then
        SKIP_CAPTURE=1
    else
        warn "Existing face enrollment is invalid. Re-enrolling now."
    fi
fi

if [ "$SKIP_CAPTURE" != "1" ]; then
    echo "========================================"
    echo "FACE REGISTRATION"
    if [ "$FORCE_ENROLL" = "1" ]; then
        echo "Force re-enroll requested."
    fi
    echo "Look directly at the selected camera."
    echo "Capturing in 3 seconds..."
    echo "========================================"

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

fi

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
import warnings

warnings.filterwarnings(
    "ignore",
    message="pkg_resources is deprecated as an API.*",
    category=UserWarning,
)

import face_recognition
import cv2
import os
import json
import time
import signal
import sys
import subprocess
import threading
from contextlib import contextmanager

@contextmanager
def suppress_native_stderr():
    """
    Suppress noisy native OpenCV/V4L stderr messages during camera open/read/release.
    FaceAuth still prints its own useful status logs.
    """
    devnull_fd = os.open(os.devnull, os.O_WRONLY)
    old_stderr_fd = os.dup(2)

    try:
        os.dup2(devnull_fd, 2)
        yield
    finally:
        os.dup2(old_stderr_fd, 2)
        os.close(old_stderr_fd)
        os.close(devnull_fd)

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
    print(f"Camera activated - looking for face on index {ir_index}")

    video = None

    with suppress_native_stderr():
        video = cv2.VideoCapture(ir_index)

    if not video or not video.isOpened():
        print(f"Camera open failed for index {ir_index}")
        return

    for _ in range(10):
        if stop_event.is_set():
            with suppress_native_stderr():
                video.release()
            print("Camera deactivated")
            return

        with suppress_native_stderr():
            video.read()

    match_count = 0

    while not stop_event.is_set():
        with suppress_native_stderr():
            ret, frame = video.read()

        if stop_event.is_set():
            break

        if not ret or frame is None:
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
    with suppress_native_stderr():
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
        if face_thread and face_thread.is_alive():
            face_thread.join(timeout=2)
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

            if stop_event is not None:
                continue

            print(f"Wake signal after {elapsed:.1f}s")

            if elapsed < 1:
                print("Quick wake - just screen dim, ignoring")
                is_locked_state = False
                lock_time = None
            else:
                print("Real lockscreen - starting camera!")
                stop_event = threading.Event()
                face_thread = threading.Thread(
                    target=face_recognition_loop,
                    args=(username, ir_index, tolerance, my_encoding, stop_event)
                )
                face_thread.daemon = True
                face_thread.start()

        elif "'LockedHint': <false>" in line or "Session.Unlock" in line:
            if not is_locked_state and stop_event is None:
                continue

            print("Screen UNLOCKED - stopping camera")
            is_locked_state = False
            lock_time = None

            if stop_event:
                stop_event.set()

                if face_thread and face_thread.is_alive():
                    face_thread.join(timeout=2)

                stop_event = None
                face_thread = None

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

# Install FaceAuth control tool
step "Installing FaceAuth control tool"

sudo tee /usr/local/bin/faceauthctl > /dev/null << 'CTL_EOF'
#!/usr/bin/env python3
import json
import os
import platform
import pwd
import subprocess
import sys
import time
import warnings

warnings.filterwarnings(
    "ignore",
    message="pkg_resources is deprecated as an API.*",
    category=UserWarning,
)
from pathlib import Path
from contextlib import contextmanager

FACEAUTH_LINE = "auth sufficient pam_exec.so quiet /usr/local/bin/faceauth"

def run(cmd):
    try:
        p = subprocess.run(cmd, text=True, capture_output=True)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except Exception as e:
        return 1, "", str(e)

def current_user():
    return os.environ.get("SUDO_USER") or os.environ.get("USER") or pwd.getpwuid(os.getuid()).pw_name

def user_home(username):
    return Path(pwd.getpwnam(username).pw_dir)

def header(title):
    print("")
    print("=" * 48)
    print(title)
    print("=" * 48)

def service_value(args):
    code, out, err = run(["systemctl"] + args + ["faceauth"])
    return out if out else err if err else "unknown"

def cmd_status():
    username = current_user()
    home = user_home(username)
    cfg = home / ".faceauth" / "config.json"
    face = home / ".faceauth" / "my_face.jpg"

    header("FaceAuth Status")
    print(f"User: {username}")
    print(f"Service active: {service_value(['is-active'])}")
    print(f"Service enabled: {service_value(['is-enabled'])}")
    print(f"Config: {'OK' if cfg.exists() else 'missing'} ({cfg})")
    print(f"Registered face: {'OK' if face.exists() else 'missing'} ({face})")

    if cfg.exists():
        try:
            data = json.loads(cfg.read_text())
            print(f"Camera index: {data.get('ir_camera')}")
            print(f"Tolerance: {data.get('tolerance')}")
            print(f"Desktop: {data.get('desktop')}")
        except Exception as e:
            print(f"Config read error: {e}")

def cmd_logs():
    since = "20 minutes ago"
    args = sys.argv[2:]
    if args:
        since = " ".join(args)

    subprocess.run([
        "journalctl",
        "-u", "faceauth",
        "--since", since,
        "-l",
        "--no-pager"
    ])

def detect_package_manager():
    for pm in ["dnf", "apt", "pacman", "zypper"]:
        code, out, err = run(["bash", "-lc", f"command -v {pm}"])
        if code == 0:
            return pm
    return "unknown"

def read_os_release():
    path = Path("/etc/os-release")
    if not path.exists():
        return "unknown"

    data = {}
    for line in path.read_text(errors="ignore").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            data[k] = v.strip('"')

    return data.get("PRETTY_NAME", "unknown")

def import_check(module):
    code, out, err = run(["python3", "-c", f"import {module}; print('OK')"])
    return "OK" if code == 0 else f"FAILED: {err or out}"

def pam_check():
    files = [
        "/etc/pam.d/gdm-password",
        "/etc/pam.d/sddm",
        "/etc/pam.d/lightdm",
    ]

    for f in files:
        path = Path(f)
        if not path.exists():
            print(f"{f}: missing")
            continue

        try:
            text = path.read_text(errors="ignore")
            print(f"{f}: {'FaceAuth configured' if FACEAUTH_LINE in text else 'no FaceAuth line'}")
        except Exception as e:
            print(f"{f}: cannot read ({e})")

@contextmanager
def suppress_native_stderr():
    devnull_fd = os.open(os.devnull, os.O_WRONLY)
    old_stderr_fd = os.dup(2)

    try:
        os.dup2(devnull_fd, 2)
        yield
    finally:
        os.dup2(old_stderr_fd, 2)
        os.close(old_stderr_fd)
        os.close(devnull_fd)

def cmd_list_cameras():
    header("FaceAuth Camera List")

    try:
        import cv2
        import numpy as np
    except Exception as e:
        print(f"OpenCV import failed: {e}")
        return 1

    found = False

    for i in range(10):
        with suppress_native_stderr():
            cap = cv2.VideoCapture(i)

        if not cap.isOpened():
            with suppress_native_stderr():
                cap.release()
            continue

        frame = None

        for _ in range(8):
            with suppress_native_stderr():
                ret, f = cap.read()
            if ret and f is not None and f.size > 0 and float(f.mean()) > 1:
                frame = f
                break

        with suppress_native_stderr():
            cap.release()

        if frame is None:
            print(f"Camera {i}: opens but no usable frame")
            found = True
            continue

        if len(frame.shape) == 2:
            diff = 0
            brightness = float(frame.mean())
        else:
            b, g, r = cv2.split(frame)
            diff = int(np.mean(np.abs(b.astype(int) - r.astype(int))))
            brightness = float(frame.mean())

        kind = "ir-like" if diff <= 2 else "rgb"
        print(f"Camera {i}: OK | type={kind} | color-diff={diff} | brightness={brightness:.2f}")
        found = True

    if not found:
        print("No usable cameras found.")

def cmd_doctor():
    username = current_user()

    header("FaceAuth Doctor Report")
    print(f"User: {username}")
    print(f"UID: {pwd.getpwnam(username).pw_uid}")
    print(f"OS: {read_os_release()}")
    print(f"Kernel: {platform.release()}")
    print(f"Package manager: {detect_package_manager()}")
    print(f"Desktop: {os.environ.get('XDG_CURRENT_DESKTOP', 'unknown')}")
    print(f"Session type: {os.environ.get('XDG_SESSION_TYPE', 'unknown')}")

    code, out, err = run(["systemctl", "status", "display-manager", "--no-pager"])
    first = out.splitlines()[0] if out else err.splitlines()[0] if err else "unknown"
    print(f"Display manager: {first}")

    print("")
    print("Service:")
    print(f"  active: {service_value(['is-active'])}")
    print(f"  enabled: {service_value(['is-enabled'])}")

    print("")
    print("Python imports:")
    checks = [
        ("setuptools compatibility", "pkg_resources"),
        ("OpenCV", "cv2"),
        ("dlib", "dlib"),
        ("face recognition models", "face_recognition_models"),
        ("face recognition", "face_recognition"),
    ]

    for label, module in checks:
        print(f"  {label}: {import_check(module)}")

    print("")
    print("PAM:")
    pam_check()

    print("")
    print("Installed files:")
    for f in ["/usr/local/bin/faceauth", "/usr/local/bin/faceauth_daemon", "/usr/local/bin/faceauthctl", "/etc/systemd/system/faceauth.service"]:
        print(f"  {f}: {'OK' if Path(f).exists() else 'missing'}")

    print("")
    cmd_list_cameras()

def get_config_path(username):
    return user_home(username) / ".faceauth" / "config.json"

def get_face_path(username):
    return user_home(username) / ".faceauth" / "my_face.jpg"

def load_config(username):
    cfg = get_config_path(username)

    data = {
        "ir_camera": 0,
        "rgb_camera": 0,
        "tolerance": 0.6,
        "max_attempts": 50,
        "desktop": os.environ.get("XDG_CURRENT_DESKTOP", "unknown").lower(),
    }

    if cfg.exists():
        try:
            data.update(json.loads(cfg.read_text()))
        except Exception as e:
            print(f"Config read warning: {e}")

    return data

def save_config(username, data):
    cfg = get_config_path(username)
    cfg.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    cfg.write_text(json.dumps(data, indent=2))
    cfg.chmod(0o600)

def restart_service():
    print("Restarting FaceAuth service...")
    code, out, err = run(["sudo", "systemctl", "restart", "faceauth"])

    if code == 0:
        print("FaceAuth service restarted.")
        return 0

    print(f"Could not restart service: {err or out}")
    print("Run manually: sudo systemctl restart faceauth")
    return 1

def analyze_frame(frame):
    import cv2
    import numpy as np

    if len(frame.shape) == 2:
        diff = 0
        brightness = float(frame.mean())
    else:
        b, g, r = cv2.split(frame)
        diff = int(np.mean(np.abs(b.astype(int) - r.astype(int))))
        brightness = float(frame.mean())

    kind = "ir-like" if diff <= 2 else "rgb"
    return kind, diff, brightness

def capture_frame(camera_index, warmup=10, attempts=30):
    import cv2

    with suppress_native_stderr():
        cap = cv2.VideoCapture(camera_index)

    if not cap.isOpened():
        with suppress_native_stderr():
            cap.release()
        return None, f"Camera {camera_index} could not be opened."

    for _ in range(warmup):
        with suppress_native_stderr():
            cap.read()

    frame = None

    for _ in range(attempts):
        with suppress_native_stderr():
            ret, f = cap.read()

        if ret and f is not None and f.size > 0 and float(f.mean()) > 1:
            frame = f
            break

        time.sleep(0.1)

    with suppress_native_stderr():
        cap.release()

    if frame is None:
        return None, f"Camera {camera_index} opened but did not return a usable frame."

    return frame, None

def cmd_test_camera():
    username = current_user()
    cfg = load_config(username)

    if len(sys.argv) >= 3:
        try:
            camera_index = int(sys.argv[2])
        except ValueError:
            print("Camera index must be a number.")
            return 1
    else:
        camera_index = int(cfg.get("ir_camera", 0))

    header("FaceAuth Camera Test")
    print(f"Testing camera index: {camera_index}")

    frame, err = capture_frame(camera_index)

    if err:
        print(f"FAILED: {err}")
        return 1

    kind, diff, brightness = analyze_frame(frame)
    print(f"OK: Camera {camera_index}")
    print(f"Type: {kind}")
    print(f"Color diff: {diff}")
    print(f"Brightness: {brightness:.2f}")
    return 0

def cmd_set_camera():
    if len(sys.argv) < 3:
        print("Usage: faceauthctl set-camera <index>")
        return 1

    try:
        camera_index = int(sys.argv[2])
    except ValueError:
        print("Camera index must be a number.")
        return 1

    username = current_user()

    header("FaceAuth Set Camera")
    print(f"Checking camera {camera_index} before saving...")

    frame, err = capture_frame(camera_index)

    if err:
        print(f"FAILED: {err}")
        return 1

    kind, diff, brightness = analyze_frame(frame)

    cfg = load_config(username)
    cfg["ir_camera"] = camera_index
    save_config(username, cfg)

    print(f"Saved camera index: {camera_index}")
    print(f"Type: {kind}")
    print(f"Color diff: {diff}")
    print(f"Brightness: {brightness:.2f}")

    restart_service()
    return 0

def cmd_enroll():
    import cv2
    import face_recognition

    username = current_user()
    cfg = load_config(username)

    if len(sys.argv) >= 3:
        try:
            camera_index = int(sys.argv[2])
        except ValueError:
            print("Camera index must be a number.")
            return 1
    else:
        camera_index = int(cfg.get("ir_camera", 0))

    face_path = get_face_path(username)

    header("FaceAuth Enrollment")
    print(f"Using camera index: {camera_index}")
    print("Look directly at the camera.")
    print("Capturing in 3 seconds...")
    time.sleep(3)

    frame, err = capture_frame(camera_index)

    if err:
        print(f"FAILED: {err}")
        return 1

    face_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)

    if not cv2.imwrite(str(face_path), frame):
        print(f"FAILED: Could not save face image to {face_path}")
        return 1

    face_path.chmod(0o600)

    try:
        image = face_recognition.load_image_file(str(face_path))
        encodings = face_recognition.face_encodings(image)
    except Exception as e:
        print(f"FAILED: Face verification error: {e}")
        return 1

    if not encodings:
        print("FAILED: No face detected. Try better lighting and keep only your face visible.")
        return 1

    if len(encodings) > 1:
        print(f"WARNING: {len(encodings)} faces detected. FaceAuth will use the first face.")

    cfg["ir_camera"] = camera_index
    save_config(username, cfg)

    print(f"Face enrolled successfully: {face_path}")
    print(f"Encodings found: {len(encodings)}")

    restart_service()
    return 0

def usage():
    print("FaceAuth control tool")
    print("")
    print("Usage:")
    print("  faceauthctl status")
    print("  faceauthctl logs [since]")
    print("  faceauthctl doctor")
    print("  faceauthctl list-cameras")
    print("  faceauthctl test-camera [index]")
    print("  faceauthctl set-camera <index>")
    print("  faceauthctl enroll [index]")
    print("")
    print("Examples:")
    print("  faceauthctl logs '10 minutes ago'")
    print("  faceauthctl test-camera 1")
    print("  faceauthctl set-camera 2")
    print("  faceauthctl enroll 2")

def main():
    if len(sys.argv) < 2:
        usage()
        return 0

    cmd = sys.argv[1]

    if cmd == "status":
        cmd_status()
    elif cmd == "logs":
        cmd_logs()
    elif cmd == "doctor":
        cmd_doctor()
    elif cmd in ("list-cameras", "cameras"):
        cmd_list_cameras()
    elif cmd == "test-camera":
        return cmd_test_camera()
    elif cmd == "set-camera":
        return cmd_set_camera()
    elif cmd == "enroll":
        return cmd_enroll()
    elif cmd in ("help", "-h", "--help"):
        usage()
    else:
        print(f"Unknown command: {cmd}")
        usage()
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())
CTL_EOF

sudo chmod +x /usr/local/bin/faceauthctl

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
echo "Installer logs saved at: $RUN_LOG_DIR"
echo "Lock your screen to test face unlock."
echo ""
echo "If it does not work immediately:"
echo "  1. Check logs: journalctl -u faceauth -e --no-pager"
echo "  2. Log out and log back in"
echo "  3. Reboot only as a last fallback"
echo ""
echo "To re-register your face later:"
echo "  faceauthctl enroll"
echo "  or: bash install.sh --force-enroll"
echo "========================================"
