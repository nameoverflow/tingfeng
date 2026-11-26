# 男角色侧脸

以已定稿的女角色侧脸为 ImageGen 风格参考。男头采用圆润的枕部、短额发和略方的下颌，脸颊到下巴是一条连续边线。头和短颈为同一剪纸，沿头骨方向转动。

原稿在 `client/src/assets/battle/male-traveller/head.png`。从仓库根目录运行 `python3 harness/animation-qa/runs/female-traveller/convert.py male`，用与女头相同的轮廓转换流程重建 `male_head.gsa`。

演武场实机对照通过。以同一站姿比较旧圆头和新侧脸，并检查两种朝向下重掌、劈剑的起跳、命中和收势。在 390 × 844 视口核对持剑男角色的额发、下颌和持剑方向。
