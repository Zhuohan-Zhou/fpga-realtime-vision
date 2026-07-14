#!/usr/bin/env python3
"""
sd_dump.py -- read raw sectors written by the FPGA and convert to PNG.

Usage (Windows, run as Administrator; find N with: wmic diskdrive list brief):
  python sd_dump.py --verify \\\\.\\PhysicalDriveN
      check the 8 test blocks written by sd_test_top

  python sd_dump.py --frame \\\\.\\PhysicalDriveN --block 4096 -o photo.png
      read one 480x272 RGB565 frame (510 blocks) starting at --block
      and save as PNG (requires: pip install pillow)

On Linux/macOS use the device path directly, e.g. /dev/sdb (with sudo).
"""
import argparse
import sys

BLOCK = 512
TEST_BASE = 2048
TEST_N = 8
W, H = 480, 272
FRAME_BYTES = W * H * 2                    # 261120
FRAME_BLOCKS = FRAME_BYTES // BLOCK        # 510


def read_blocks(dev, start, count):
    with open(dev, 'rb') as f:
        f.seek(start * BLOCK)
        return f.read(count * BLOCK)


def verify(dev):
    data = read_blocks(dev, TEST_BASE, TEST_N)
    errors = 0
    for blk in range(TEST_N):
        blkno = TEST_BASE + blk
        for i in range(BLOCK):
            expect = (i & 0xFF) ^ (blkno & 0xFF)
            got = data[blk * BLOCK + i]
            if got != expect:
                if errors < 10:
                    print(f"MISMATCH blk {blkno} byte {i}: "
                          f"got {got:02X} expect {expect:02X}")
                errors += 1
    if errors == 0:
        print(f"PASS: all {TEST_N} test blocks correct "
              f"({TEST_N * BLOCK} bytes)")
    else:
        print(f"FAIL: {errors} byte errors")
    return errors == 0


def dump_frame(dev, block, out):
    from PIL import Image
    raw = read_blocks(dev, block, FRAME_BLOCKS)
    img = Image.new('RGB', (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            i = (y * W + x) * 2
            v = (raw[i] << 8) | raw[i + 1]   # {high byte, low byte}
            r = (v >> 11) & 0x1F
            g = (v >> 5) & 0x3F
            b = v & 0x1F
            px[x, y] = ((r << 3) | (r >> 2),
                        (g << 2) | (g >> 4),
                        (b << 3) | (b >> 2))
    img.save(out)
    print(f"saved {out} ({W}x{H}) from block {block}")


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('device', help=r'\\.\PhysicalDriveN or /dev/sdX')
    ap.add_argument('--verify', action='store_true')
    ap.add_argument('--frame', action='store_true')
    ap.add_argument('--block', type=int, default=4096)
    ap.add_argument('-o', '--out', default='photo.png')
    a = ap.parse_args()

    if a.verify:
        sys.exit(0 if verify(a.device) else 1)
    elif a.frame:
        dump_frame(a.device, a.block, a.out)
    else:
        ap.print_help()
