# Nanami app icon

| File | What it is |
|---|---|
| `Nanami.icns` | Bundled into `Nanami.app` by `mac-app/Makefile` — variant A |
| `Nanami-1024.png` | RGBA master, variant A (1024×1024) |
| `Nanami-alt.icns` | Variant B, ready to swap in |
| `Nanami-alt-1024.png` | RGBA master, variant B |

Both variants started life as 1254×1254 artwork with a real alpha channel,
resized to 1024² and packed. To switch variants, just overwrite the main
files:

```sh
cp Nanami-alt.icns Nanami.icns
cp Nanami-alt-1024.png Nanami-1024.png
```

## What's in the `.icns`

Ten RGBA PNG entries:

| osType | size | notes |
|---|---|---|
| `icp4` | 16×16 | menu bar |
| `icp5` | 32×32 | Finder list view |
| `icp6` | 64×64 | |
| `ic07` | 128×128 | |
| `ic08` | 256×256 | |
| `ic09` | 512×512 | largest size 10.9 renders |
| `ic11` | 32×32 | 16pt @2x |
| `ic12` | 64×64 | 32pt @2x |
| `ic13` | 256×256 | 128pt @2x |
| `ic14` | 512×512 | 256pt @2x |

`ic10` (1024×1024) is left out. 10.9 never renders above 512pt, and that one
entry cost 1.5 MB on its own.

## Regenerating after replacing the master

```sh
python3 - <<'PY'
from PIL import Image
import struct, io
im = Image.open("Nanami-1024.png").convert("RGBA")
L = Image.Resampling.LANCZOS
out = bytearray()
for typ, size in [(b'icp4',16),(b'icp5',32),(b'icp6',64),(b'ic07',128),
                  (b'ic08',256),(b'ic09',512),(b'ic11',32),(b'ic12',64),
                  (b'ic13',256),(b'ic14',512)]:
    b = io.BytesIO(); im.resize((size,size), L).save(b, "PNG", optimize=True)
    d = b.getvalue(); out += typ + struct.pack('>I', len(d)+8) + d
open("Nanami.icns","wb").write(b'icns' + struct.pack('>I', len(out)+8) + bytes(out))
PY
```

A replacement master needs to be square with a real alpha channel. The
artwork here fills about 75% of the frame; go much below that and the icon
looks small next to everything else in the Dock, since AppKit renders them
all at the same box size.

One thing to watch if you regenerate this from generated artwork rather than
handing it a PNG: image models tend to draw "transparency" as a grey and
white checkerboard in the RGB channels instead of an actual alpha channel. If
the corners of your master aren't `(0,0,0,0)`, it did that, and you'll need
to key the checkerboard out (flood fill from the border over the two
checkerboard tones, then defringe) before packing.
