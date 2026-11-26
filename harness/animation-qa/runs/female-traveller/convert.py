"""Convert the generated head mask to the rig's head-local coordinates."""
from pathlib import Path

import cv2

root = Path(__file__).resolve().parents[4]
source = root / "client/src/assets/battle/female-traveller/head.png"
output = root / "client/gsa/src/female_head.gsa"
alpha = cv2.imread(str(source), cv2.IMREAD_UNCHANGED)[:, :, 3]
contours, _ = cv2.findContours((alpha >= 128).astype("uint8"), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
# Retain the registration and simplification of the original profile cutout.
scale = 0.078
edge = cv2.approxPolyDP(max(contours, key=cv2.contourArea), 0.14 / scale, True)[:, 0]
pairs = [f"({(x - 169) * scale:.2f}, {(y - 177) * scale:.2f})" for x, y in edge]
lines = ["// Generated from the female-traveller head mask by convert.py.", "",
         "pub def outline(): List (Float, Float) = ["]
for i in range(0, len(pairs), 4):
    lines.append("    " + ", ".join(pairs[i:i + 4]) + ("," if i + 4 < len(pairs) else ""))
output.write_text("\n".join(lines + ["]", ""]))
