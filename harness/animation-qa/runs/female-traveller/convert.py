"""Convert the generated head mask to the rig's head-local coordinates."""
import argparse
from pathlib import Path

import cv2

root = Path(__file__).resolve().parents[4]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("profile", choices=["female", "male"], nargs="?", default="female")
profile = parser.parse_args().profile
source = root / f"client/src/assets/battle/{profile}-traveller/head.png"
output = root / f"client/gsa/src/{profile}_head.gsa"
alpha = cv2.imread(str(source), cv2.IMREAD_UNCHANGED)[:, :, 3]
contours, _ = cv2.findContours((alpha >= 128).astype("uint8"), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
# Retain the registration and simplification of the original profile cutout.
anchor_x, anchor_y = (169, 177) if profile == "female" else (163, 187)
scale = 0.078
edge = cv2.approxPolyDP(max(contours, key=cv2.contourArea), 0.14 / scale, True)[:, 0]
pairs = [f"({(x - anchor_x) * scale:.2f}, {(y - anchor_y) * scale:.2f})" for x, y in edge]
lines = [f"// Generated from the {profile}-traveller head mask by convert.py.", "",
         "pub def outline(): List (Float, Float) = ["]
for i in range(0, len(pairs), 4):
    lines.append("    " + ", ".join(pairs[i:i + 4]) + ("," if i + 4 < len(pairs) else ""))
output.write_text("\n".join(lines + ["]", ""]))
