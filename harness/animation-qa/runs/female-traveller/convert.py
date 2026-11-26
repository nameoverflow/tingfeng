"""Convert the generated cutouts' alpha boundary to the rig's polygon format."""
from pathlib import Path

import cv2

root = Path(__file__).resolve().parents[4]
source = root / "client/src/assets/battle/female-traveller"
output = root / "client/gsa/src/female_cutouts.gsa"
lines = ["// Generated from the female-traveller alpha masks by convert.py."]

# Registration points are the skull centre and base of the collar, in source pixels.
for name, anchor, scale in [
    ("head", (169, 177), 0.078),
    ("jacket", (224, 77), 0.095),
]:
    alpha = cv2.imread(str(source / f"{name}.png"), cv2.IMREAD_UNCHANGED)[:, :, 3]
    contours, _ = cv2.findContours((alpha >= 128).astype("uint8"), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    edge = max(contours, key=cv2.contourArea)
    points = cv2.approxPolyDP(edge, 0.14 / scale, True)[:, 0]
    pairs = [f"({(x - anchor[0]) * scale:.2f}, {(y - anchor[1]) * scale:.2f})" for x, y in points]
    lines += ["", f"pub def {name}(): List (Float, Float) = ["]
    for i in range(0, len(pairs), 4):
        lines.append("    " + ", ".join(pairs[i:i + 4]) + ("," if i + 4 < len(pairs) else ""))
    lines.append("]")
output.write_text("\n".join(lines) + "\n")
