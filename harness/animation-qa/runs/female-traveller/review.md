# 女角色素剪影

身体沿用原有躯干和四肢轮廓。两种发式共用同一个无五官头型，由额面、脸颊和略向前收的下颌表现朝向。发束与头骨仍使用原来的锚点。

ImageGen 生成的头部透明原稿在 `client/src/assets/battle/female-traveller/head.png`。这里的 `convert.py` 用 OpenCV 将 alpha 外轮廓转换为 `female_head.gsa`，坐标相对头骨中心和半径。

演武场按相同时间点检查了披发重掌和高马尾劈剑的站姿、起跳、命中和收势，并在 390 × 844 视口核对持剑、闪避。腰腿回到连续素剪影，侧脸只有外缘。
