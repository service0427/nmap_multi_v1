import sys
import os
import time
import random
import base64
import subprocess

def type_humanized(device_id, text):
    if not text:
        return
    
    chars = list(text)
    print(f"[*] Humanized Typing Starting: {text} ({len(chars)} chars)")
    
    for i, char in enumerate(chars):
        encoded = base64.b64encode(char.encode('utf-8')).decode('ascii')
        
        # ADB Input per character
        cmd = ["adb", "-s", device_id, "shell", "am", "broadcast", "-a", "ADB_INPUT_B64", "--es", "msg", encoded]
        try:
            subprocess.run(cmd, capture_output=True, timeout=5)
        except subprocess.TimeoutExpired:
            print(f" [-] Typing character '{char}' Timeout (5s)")
            break
        
        # Delay logic: 1-5 chars (0.1~0.5s), 6+ chars (0.1s)
        if i < 5:
            delay = 0.1 + random.random() * 0.4
        else:
            delay = 0.1
            
        time.sleep(delay)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(1)
    type_humanized(sys.argv[1], sys.argv[2])
