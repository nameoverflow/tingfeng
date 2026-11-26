"""Register the generated palm and shoe cutouts to the wrist and ground line."""
from pathlib import Path

import cv2

root = Path(__file__).resolve().parents[4]
source = root / "client/src/assets/battle/ink-marks"
lines = ["// Generated from ink-marks by compact-figures/convert.py.", ""]
for name in ("palm", "shoe"):
    alpha = cv2.imread(str(source / f"{name}.png"), cv2.IMREAD_UNCHANGED)[:, :, 3]
    height, width = alpha.shape
    contours, _ = cv2.findContours((alpha >= 128).astype("uint8"), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    edge = cv2.approxPolyDP(max(contours, key=cv2.contourArea), width * 0.005, True)[:, 0]
    if name == "palm":
        points = [(13.8 * x / (width - 1), 6.4 * (0.64 - y / (height - 1))) for x, y in edge]
    else:
        points = [(19.0 * x / (width - 1) - 5.3, 6.7 * (1 - y / (height - 1))) for x, y in edge]
    pairs = [f"({x:.2f}, {y:.2f})" for x, y in points]
    lines.append(f"pub def {name}(): List (Float, Float) = [")
    for i in range(0, len(pairs), 4):
        lines.append("    " + ", ".join(pairs[i:i + 4]) + ("," if i + 4 < len(pairs) else ""))
    lines += ["]", ""]
(root / "client/gsa/src/ink_marks.gsa").write_text("\n".join(lines))
