"""Register the generated ink cutouts to the figure rig."""
from pathlib import Path

import cv2

root = Path(__file__).resolve().parents[4]
source = root / "client/src/assets/battle/ink-marks"
lines = ["// Generated from ink-marks by compact-figures/convert.py.", ""]
for name in ("palm", "shoe", "core", "stroke"):
    alpha = cv2.imread(str(source / f"{name}.png"), cv2.IMREAD_UNCHANGED)[:, :, 3]
    height, width = alpha.shape
    contours, _ = cv2.findContours((alpha >= 128).astype("uint8"), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    tolerance = height * 0.022 if name == "stroke" else width * 0.005
    edge = cv2.approxPolyDP(max(contours, key=cv2.contourArea), tolerance, True)[:, 0]
    if name == "palm":
        points = [(13.8 * x / (width - 1), 6.4 * (0.64 - y / (height - 1))) for x, y in edge]
    elif name == "shoe":
        points = [(19.0 * x / (width - 1) - 5.3, 6.7 * (1 - y / (height - 1))) for x, y in edge]
    elif name == "core":
        points = [(x / (width - 1) - 0.5, y / (height - 1)) for x, y in edge]
    else:
        # Specify the stroke in units of its width. Only the straight middle
        # stretches along a bone, so the rounded end caps keep their aspect.
        points = [(x / (height - 1), y / (height - 1) - 0.5) for x, y in edge]
        lines += [f"pub def strokeLength(): Float = {(width - 1) / (height - 1):.3f}", ""]
    pairs = [f"({x:.3f}, {y:.3f})" if name in ("core", "stroke") else f"({x:.2f}, {y:.2f})" for x, y in points]
    lines.append(f"pub def {name}(): List (Float, Float) = [")
    for i in range(0, len(pairs), 4):
        lines.append("    " + ", ".join(pairs[i:i + 4]) + ("," if i + 4 < len(pairs) else ""))
    lines += ["]", ""]
(root / "client/gsa/src/ink_marks.gsa").write_text("\n".join(lines))
