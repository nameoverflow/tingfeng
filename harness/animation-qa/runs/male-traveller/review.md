# 半束发男侠剪影

男角色保留古装武侠身份。发顶顺着头形，长发在脑后半束，发尾垂到颈后。前额留简洁的碎发，侧脸维持平滑的鼻口线。发束与后颈间保留空隙，小尺寸下仍能看清。

ImageGen 生成的透明头颈原稿在 `client/src/assets/battle/male-traveller/head.png`。运行 `python3 harness/animation-qa/runs/female-traveller/convert.py male` 会在束口下提取与后颈分开的发束，按原轮廓顺序输出固定和活动两段。渲染时只弯折活动段，并沿用战斗时钟回采的头部运动。

在演武场检查重掌、反向劈剑以及 390 × 844 视口的站姿、起步、闪避和收势。静止帧里能看见后颈和束发，掠步时发梢向后扬起。
