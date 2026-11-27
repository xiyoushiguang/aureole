#!/usr/bin/env python3
# readme-gif.py <frames dir> <out.gif> [width]: the README's animation from the frames `--film --scene readme` draws.
# Cuts between the notch, the panel and the card get a four-frame cross-fade, the last frames fade back to the
# first so the loop has no jump, and the colours are one palette picked for this film with an ordered dither
# (a pattern that stays put from frame to frame, so only what really changes is stored).
# Needs Pillow and ffmpeg.
import glob, os, shutil, subprocess, sys
from PIL import Image

src, out = sys.argv[1], sys.argv[2]
W = int(sys.argv[3]) if len(sys.argv) > 3 else 960
FPS = 12.5                       # Filmer.readmeFps
CUTS = [1.4, 5.2, 8.6]           # Filmer.readme: the panel opens, the card comes up, the card goes
FADE = 4
ffmpeg = shutil.which('ffmpeg') or os.path.expanduser('~/.local/bin/ffmpeg')

files = sorted(glob.glob(os.path.join(src, 'f*.jpg')))
if not files:
    sys.exit(f'no frames in {src}')
first = Image.open(files[0])
H = round(first.height * W / first.width / 2) * 2
frames = [Image.open(f).convert('RGB').resize((W, H), Image.LANCZOS) for f in files]
shown = list(frames)
for t in CUTS:
    c = int(round(t * FPS))
    for j in range(FADE):
        if c + j < len(frames):
            shown[c + j] = Image.blend(frames[c - 1], frames[c + j], (j + 1) / (FADE + 1))
n = len(frames)
for j in range(FADE):
    shown[n - FADE + j] = Image.blend(frames[n - FADE + j], frames[0], (j + 1) / (FADE + 1))

ff = subprocess.Popen([ffmpeg, '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}', '-r', str(FPS), '-i', '-',
                       '-filter_complex',
                       '[0:v]split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle',
                       '-loop', '0', out], stdin=subprocess.PIPE)
for im in shown:
    ff.stdin.write(im.tobytes())
ff.stdin.close()
if ff.wait() != 0:
    sys.exit('ffmpeg failed')
print(f'{out}: {W}x{H}, {len(shown)} frames, {os.path.getsize(out) / 1e6:.2f} MB')
