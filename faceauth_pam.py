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