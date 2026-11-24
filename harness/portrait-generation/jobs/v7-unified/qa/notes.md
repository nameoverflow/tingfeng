# V7 unified portrait QA

V7 was generated after feedback that v6's low tiers were too mild, middle tiers too unattractive, high tiers insufficiently beautiful, paper too yellow and the male/female faces, hairstyles and clothing too similar. The v6 results were not accepted into the game.

The 12 source images, the contact sheet and a 64 px-per-tile sheet were inspected. The v7 0/2 faces are exaggerated and distinct; 4/6 are pleasant everyday faces; 8/10 have more idealized faces and different expressions. Male and female counterparts use different face shapes, hair silhouettes, collar colors and, in several cases, angles. The hair and collar remain visible in the small preview. The palette is pale grey-ivory paper with dark ink and muted watercolor. The images remain hand-painted illustrations, with more facial detail than the locked v4 set.

The first female 10 candidate had cropped hair and was regenerated. The first female 00 and 02 candidates resembled their male counterparts and were regenerated with different face shapes, hairstyles and angles. The accepted outputs are 1254×1254; `manifest.tsv` records the dimensional check. The 512×512 client images are mechanical resizes of those originals.

The browser check loaded all 18 portrait paths (12 v7 and six existing unknown-gender fallbacks) without errors and inspected both sexes in creation preview and the character panel. A separate check covered score clamping, odd-score rounding and existence of all 33 gender/score paths. The v4 originals remain unchanged.
