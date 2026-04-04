#!/bin/bash

echo "========================================"
echo "   FaceAuth Universal Installer"
echo "========================================"

USERNAME=$(whoami)
USER_ID=$(id -u)
echo "Installing for user: $USERNAME (UID: $USER_ID)"

# Install dependencies
echo ""
echo "Installing dependencies..."
if command -v dnf &> /dev/null; then
    sudo dnf install -y python3 python3-pip python3-devel gcc-c++ cmake pam-devel git -q
    sudo pip install face_recognition opencv-python --break-system-packages --quiet
elif command -v apt &> /dev/null; then
    sudo apt update -q
    sudo apt install -y python3 python3-pip python3-dev build-essential cmake libpam-dev git -q
    sudo pip install face_recognition opencv-python --break-system-packages --quiet
elif command -v pacman &> /dev/null; then
    sudo pacman -S --noconfirm python python-pip cmake base-devel pam git
    sudo pip install face_recognition opencv-python --break-system-packages --quiet
else
    echo "Unsupported distro!"
    exit 1
fi
echo "Dependencies ready!"

# Detect desktop environment
echo ""
echo "Detecting desktop environment..."
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

# Detect IR camera - only count cameras with valid frames
echo ""
echo "Detecting cameras..."
IR_INDEX=$(python3 -c "
import cv2
import numpy as np

valid_cameras = []
for i in range(10):
    cap = cv2.VideoCapture(i)
    if cap.isOpened():
        frame = None
        for _ in range(5):
            ret, f = cap.read()
            if ret and f is not None and f.size > 0 and f.mean() > 1:
                frame = f
                break
        if frame is not None:
            b, g, r = cv2.split(frame)
            diff = int(np.mean(np.abs(b.astype(int) - r.astype(int))))
            valid_cameras.append((i, diff))
        cap.release()

ir = None
rgb = None
for idx, diff in valid_cameras:
    if diff == 0 and ir is None:
        ir = idx
    elif diff > 5 and rgb is None:
        rgb = idx

result = ir if ir is not None else (rgb if rgb is not None else 0)
print(result)
" 2>/dev/null)

echo "IR camera detected at index: $IR_INDEX"

# Create faceauth directory
mkdir -p /home/$USERNAME/.faceauth

# Save config
python3 -c "
import json
config = {
    'ir_camera': $IR_INDEX,
    'rgb_camera': 0,
    'tolerance': 0.6,
    'max_attempts': 50,
    'desktop': '$DE'
}
with open('/home/$USERNAME/.faceauth/config.json', 'w') as f:
    json.dump(config, f)
print('Config saved!')
"

# Capture face
echo ""
echo "========================================"
echo "FACE REGISTRATION"
echo "Look at the camera!"
echo "Capturing in 3 seconds..."
echo "========================================"

python3 -c "
import cv2, time, sys
import numpy as np

ir_index = $IR_INDEX
cap = cv2.VideoCapture(ir_index)

if not cap.isOpened():
    print('IR camera failed! Trying index 0...')
    cap = cv2.VideoCapture(0)

# Warmup camera
time.sleep(3)
for _ in range(15):
    cap.read()

# Capture valid frame
frame = None
for _ in range(10):
    ret, f = cap.read()
    if ret and f is not None and f.size > 0 and f.mean() > 1:
        frame = f
        break

cap.release()

if frame is not None:
    cv2.imwrite('/home/$USERNAME/.faceauth/my_face.jpg', frame)
    print('Face captured!')
else:
    print('Capture failed!')
    sys.exit(1)
" 2>/dev/null

if [ $? -ne 0 ]; then
    echo "Face capture failed! Run installer again."
    exit 1
fi

# Verify face
echo "Verifying face..."
python3 -c "
import face_recognition, sys
image = face_recognition.load_image_file('/home/$USERNAME/.faceauth/my_face.jpg')
encodings = face_recognition.face_encodings(image)
if encodings:
    print('Face verified!')
else:
    print('No face detected! Try better lighting.')
    sys.exit(1)
"

if [ $? -ne 0 ]; then
    echo "Face verification failed! Run installer again in better lighting."
    exit 1
fi

# Write daemon
echo ""
echo "Installing FaceAuth daemon..."
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

TOKEN_FILE = "/tmp/faceauth_token"

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
    with open(TOKEN_FILE, "w") as f:
        f.write(f"{username}:{time.time()}")
    os.chmod(TOKEN_FILE, 0o666)

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
import sys
import time

TOKEN_FILE = "/tmp/faceauth_token"
TOKEN_VALIDITY = 10

def check_token(username):
    try:
        if not os.path.exists(TOKEN_FILE):
            return False
        with open(TOKEN_FILE, "r") as f:
            content = f.read().strip()
        token_user, timestamp = content.split(":")
        timestamp = float(timestamp)
        age = time.time() - timestamp
        if token_user == username and age < TOKEN_VALIDITY:
            os.remove(TOKEN_FILE)
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
echo ""
echo "Installing systemd service..."
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
ExecStartPre=/bin/bash -c 'until [ -S /run/user/$USER_ID/bus ]; do sleep 0.5; done; sleep 5'
ExecStart=/usr/bin/python3 /usr/local/bin/faceauth_daemon $USERNAME
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable faceauth
sudo systemctl restart faceauth

# Setup PAM
echo ""
echo "Setting up PAM..."
if [ "$DE" = "gnome" ]; then
    if [ ! -f /etc/pam.d/gdm-password.backup ]; then
        sudo cp /etc/pam.d/gdm-password /etc/pam.d/gdm-password.backup
    fi
    if ! grep -q "faceauth" /etc/pam.d/gdm-password; then
        sudo sed -i '1s/^/auth sufficient pam_exec.so quiet \/usr\/local\/bin\/faceauth\n/' /etc/pam.d/gdm-password
        echo "PAM configured!"
    else
        echo "PAM already configured!"
    fi
fi

echo ""
echo "========================================"
echo "FaceAuth installed successfully!"
echo "Reboot and lock screen to test!"
echo "========================================"
