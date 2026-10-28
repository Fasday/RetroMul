"""Contact sheet of the games' captures: montage.py SHOTS_DIR OUT.png [frame-file]"""
import os
import sys
from PIL import Image, ImageDraw

root = sys.argv[1]
out = sys.argv[2]
pick = sys.argv[3] if len(sys.argv) > 3 else 'last.bmp'
games = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)))
cols = 5
w, h = 240, 136
rows = (len(games) + cols - 1) // cols
sheet = Image.new('RGB', (cols * w, rows * (h + 14)), (40, 40, 40))
draw = ImageDraw.Draw(sheet)
for i, g in enumerate(games):
    x = (i % cols) * w
    y = (i // cols) * (h + 14)
    p = os.path.join(root, g, pick)
    if not os.path.exists(p):
        shots = sorted(f for f in os.listdir(os.path.join(root, g)) if f.endswith('.bmp'))
        p = os.path.join(root, g, shots[-1]) if shots else None
    if p:
        try:
            im = Image.open(p).convert('RGB').resize((w, h))
            sheet.paste(im, (x, y + 14))
        except Exception:
            pass
    draw.text((x + 2, y), g[:38], fill=(255, 255, 0))
sheet.save(out)
print(out)
