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
