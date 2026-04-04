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
    username = sys.argv[1] if len(sys.argv) > 1 else "neeschal"
    run_daemon(username)
