import sys
import os
import json

# Add wifi_multi to python path
sys.path.append("/home/tech/nmap_multi_v1/wifi_multi")
from smart_toggle import SmartToggle

toggle = SmartToggle(11)
print("--- Starting Diagnosis for Subnet 11 ---")
diag = toggle.diagnose_problem()
print(json.dumps(diag, indent=2))
print("--- End of Diagnosis ---")
