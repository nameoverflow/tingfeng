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
# Head-bone registration in each source mask.
anchor_x, anchor_y, scale = (169, 177, 0.078) if profile == "female" else (254, 216, 0.067)
edge = cv2.approxPolyDP(max(contours, key=cv2.contourArea), 0.14 / scale, True)[:, 0]
sections = [("outline", edge)]
lines = [f"// Generated from the {profile}-traveller head mask by convert.py.", ""]
if profile == "male":
    # The tied lock separates from the neck below this scanline. Keep its
    # vertices in outline order so the animated and fixed arcs share a fill.
    tie_y = 305
    lower = (alpha >= 128).astype("uint8")
    lower[:tie_y] = 0
    _, labels = cv2.connectedComponents(lower)
    lock = labels[tie_y, 85]
    assert lock and lock != labels[tie_y, 250]
    loose = [labels[y, x] == lock for x, y in edge]
    starts = [i for i, moves in enumerate(loose) if moves and not loose[i - 1]]
    assert len(starts) == 1
    start = starts[0]
    ordered = list(edge[start:]) + list(edge[:start])
    length = sum(loose)
    sections = [("outline", ordered[length:]), ("looseHair", ordered[:length])]
    lines += [f"pub def tieY(): Float = {(tie_y - anchor_y) * scale:.2f}", ""]
for name, points in sections:
    pairs = [f"({(x - anchor_x) * scale:.2f}, {(y - anchor_y) * scale:.2f})" for x, y in points]
    lines.append(f"pub def {name}(): List (Float, Float) = [")
    for i in range(0, len(pairs), 4):
        lines.append("    " + ", ".join(pairs[i:i + 4]) + ("," if i + 4 < len(pairs) else ""))
    lines += ["]", ""]
output.write_text("\n".join(lines))
