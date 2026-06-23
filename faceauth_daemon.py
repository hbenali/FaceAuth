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
import select
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
        max_scan_seconds = int(config.get("max_scan_seconds", 30))
        scan_retry_cooldown_seconds = int(config.get("scan_retry_cooldown_seconds", 20))
        desktop = str(config.get("desktop", "")).lower()
    except:
        ir_index = 0
        tolerance = 0.6
        max_scan_seconds = 30
        scan_retry_cooldown_seconds = 20
        desktop = ""
    image = face_recognition.load_image_file(face_path)
    encodings = face_recognition.face_encodings(image)
    if not encodings:
        sys.exit(1)
    return ir_index, tolerance, max_scan_seconds, scan_retry_cooldown_seconds, encodings[0], desktop

def write_token(username):
    token_file = get_token_file()

    fd = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)

    with os.fdopen(fd, "w") as f:
        f.write(f"{username}:{time.time()}")

    os.chmod(token_file, 0o600)

def _try_dbus_unlock(dest, obj_path, method):
    try:
        p = subprocess.run(
            ["gdbus", "call", "--session",
             "--dest", dest,
             "--object-path", obj_path,
             "--method", method,
             "false"],
            capture_output=True, text=True, timeout=5
        )
        return p.returncode == 0
    except Exception:
        return False

def unlock_screen(desktop=""):
    """
    Send an unlock signal. Tries the screensaver D-Bus interfaces that match the
    active desktop first, then falls back to the XDG standard, then to logind.

    Works with GNOME (gnome-shell), KDE Plasma (ksmserver/kscreenlocker), and
    any desktop that implements org.freedesktop.ScreenSaver.
    """
    desktop = (desktop or os.environ.get("XDG_CURRENT_DESKTOP", "")).lower()
    is_kde = "kde" in desktop or "plasma" in desktop

    if is_kde:
        methods = [
            ("org.freedesktop.ScreenSaver", "/ScreenSaver", "org.freedesktop.ScreenSaver.SetActive"),
            ("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver.SetActive"),
            ("org.kde.screensaver", "/ScreenSaver", "org.kde.screensaver.SetActive"),
            ("org.kde.screensaver", "/org/freedesktop/ScreenSaver", "org.kde.screensaver.SetActive"),
            ("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver.SetActive"),
        ]
    else:
        methods = [
            ("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver.SetActive"),
            ("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver.SetActive"),
            ("org.freedesktop.ScreenSaver", "/ScreenSaver", "org.freedesktop.ScreenSaver.SetActive"),
            ("org.kde.screensaver", "/ScreenSaver", "org.kde.screensaver.SetActive"),
        ]

    for dest, obj_path, method in methods:
        if _try_dbus_unlock(dest, obj_path, method):
            print(f"Unlock signal sent via {dest}!")
            return

    try:
        subprocess.run(["loginctl", "unlock-sessions"],
                       capture_output=True, text=True, timeout=5)
        print("Unlock signal sent via loginctl!")
    except Exception as e:
        print(f"Unlock error: {e}")

def face_recognition_loop(username, ir_index, tolerance, max_scan_seconds, my_encoding, stop_event, desktop=""):
    print(f"Camera activated - looking for face on index {ir_index}")
    scan_started_at = time.time()

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
        elapsed = time.time() - scan_started_at

        if elapsed >= max_scan_seconds:
            print(f"Face scan timed out after {max_scan_seconds}s - stopping camera")
            stop_event.set()
            break

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
                    unlock_screen(desktop)
                    stop_event.set()
                    break
            else:
                match_count = max(0, match_count - 1)
        time.sleep(0.1)
    with suppress_native_stderr():
        video.release()
    print("Camera deactivated")

def run_daemon(username):
    print(f"FaceAuth daemon starting for {username}")
    ir_index, tolerance, max_scan_seconds, scan_retry_cooldown_seconds, my_encoding, desktop = load_config(username)

    is_kde = "kde" in desktop or "plasma" in desktop
    if is_kde:
        print("KDE Plasma detected - lock events will trigger scan immediately")

    stop_event = None
    face_thread = None
    lock_time = None
    is_locked_state = False
    session_awake = False
    last_scan_end = 0

    proc = subprocess.Popen(
        ["gdbus", "monitor", "--system",
         "--dest", "org.freedesktop.login1"],
        stdout=subprocess.PIPE,
        text=True
    )

    print("Watching for real lockscreen events...")

    def cleanup_finished_scan():
        nonlocal stop_event, face_thread, last_scan_end

        if stop_event and face_thread and not face_thread.is_alive():
            stop_event = None
            face_thread = None
            last_scan_end = time.time()
            print("Camera scan session ended")

    def start_scan(reason):
        nonlocal stop_event, face_thread

        cleanup_finished_scan()

        if stop_event is not None:
            return

        print(reason)
        stop_event = threading.Event()
        face_thread = threading.Thread(
            target=face_recognition_loop,
            args=(username, ir_index, tolerance, max_scan_seconds, my_encoding, stop_event, desktop)
        )
        face_thread.daemon = True
        face_thread.start()

    def stop_scan():
        nonlocal stop_event, face_thread, last_scan_end

        if stop_event:
            stop_event.set()

            if face_thread and face_thread.is_alive():
                face_thread.join(timeout=2)

            stop_event = None
            face_thread = None
            last_scan_end = time.time()

    def handle_exit(sig, frame):
        stop_scan()
        proc.terminate()
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_exit)
    signal.signal(signal.SIGINT, handle_exit)

    while True:
        cleanup_finished_scan()

        # If a scan timed out but the lockscreen is still awake, retry after cooldown.
        if (
            is_locked_state
            and session_awake
            and stop_event is None
            and face_thread is None
            and last_scan_end
            and (time.time() - last_scan_end) >= scan_retry_cooldown_seconds
        ):
            start_scan(f"Locked session still awake - retrying face scan after {scan_retry_cooldown_seconds}s cooldown")

        ready, _, _ = select.select([proc.stdout], [], [], 0.5)

        if not ready:
            continue

        line = proc.stdout.readline()

        if not line:
            break

        line = line.strip()

        if "'IdleHint': <true>" in line:
            session_awake = False

        if "'LockedHint': <true>" in line:
            is_locked_state = True
            lock_time = time.time()
            last_scan_end = 0

            if is_kde:
                # KDE's screen locker (kscreenlocker) is immediately interactive
                # when LockedHint is set, and does not toggle IdleHint the way
                # GNOME does. Start scanning right away instead of waiting for a
                # wake event that never arrives.
                session_awake = True
                print("Lock signal received - starting camera (KDE)...")
                if stop_event is None:
                    start_scan("KDE lockscreen - starting camera!")
                else:
                    print("Scan already running - monitoring...")
            else:
                session_awake = False
                print("Lock signal received - monitoring...")

        elif "'IdleHint': <false>" in line and is_locked_state:
            session_awake = True
            elapsed = time.time() - lock_time if lock_time else 0

            if stop_event is not None:
                continue

            print(f"Wake signal after {elapsed:.1f}s")

            if elapsed < 1:
                print("Quick wake - just screen dim, ignoring")
                is_locked_state = False
                session_awake = False
                lock_time = None
                last_scan_end = 0
            else:
                start_scan("Real lockscreen - starting camera!")

        elif "'LockedHint': <false>" in line or "Session.Unlock" in line:
            if not is_locked_state and stop_event is None:
                continue

            print("Screen UNLOCKED - stopping camera")
            is_locked_state = False
            session_awake = False
            lock_time = None
            last_scan_end = 0
            stop_scan()

if __name__ == "__main__":
    username = sys.argv[1] if len(sys.argv) > 1 else "FACEAUTH_USER"
    run_daemon(username)