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
            print(f"Max scan seconds: {data.get('max_scan_seconds', 30)}")
            print(f"Scan retry cooldown seconds: {data.get('scan_retry_cooldown_seconds', 20)}")
            print(f"Desktop: {data.get('desktop')}")
            print(f"Display manager: {data.get('display_manager', 'unknown')}")
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
        "/etc/pam.d/kde",
        "/etc/pam.d/kscreenlocker",
        "/etc/pam.d/lightdm",
    ]

    for f in files:
        path = Path(f)
        if not path.exists():
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

def detect_display_manager():
    """Return the active display manager service name (sddm/gdm/lightdm/...) or ''."""
    for candidate in ("sddm", "gdm", "gdm3", "lightdm", "lxdm", "plasmalogin"):
        code, _, _ = run(["systemctl", "is-active", "--quiet", candidate])
        if code == 0:
            return candidate
    code, out, err = run(["systemctl", "status", "display-manager", "--no-pager"])
    first = out.splitlines()[0] if out else err.splitlines()[0] if err else ""
    return first or "unknown"

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
    print(f"Display manager: {detect_display_manager()}")

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