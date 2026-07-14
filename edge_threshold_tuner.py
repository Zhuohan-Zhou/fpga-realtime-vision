"""
edge_threshold_tuner.py

Reproduces the FPGA's actual edge-detection pipeline in Python (not full
Canny) so EDGE_THRESH can be tuned live on a webcam feed instead of by
recompiling Quartus every time:

    gaussian_blur3x3.v  ->  sobel_edge.v  ->  nms_thresh.v

Every step below mirrors the fixed-point integer math in those three
Verilog files as closely as numpy allows, including:
  - the exact 3x3 blur kernel [1 2 1;2 4 2;1 2 1] >> 4 (integer, no float)
  - the exact Sobel kernels and the |Gx|+|Gy| (L1) magnitude, not sqrt
  - the same cheap direction bucketing (|Gx| vs 2x|Gy| shift-compare,
    no atan2/divider)
  - the same NMS neighbor selection per direction bucket
  - the same asymmetric ">"/">=" tie-break nms_thresh.v uses so a hard
    step edge doesn't come out 2px wide

What's deliberately NOT reproduced: hysteresis/double-threshold linking
(the board doesn't do that either -- see nms_thresh.v's header comment
for why). So this is "what the board would show", not full OpenCV Canny.

Usage:
    pip install opencv-python numpy
    python edge_threshold_tuner.py [camera_index]

Controls:
    q / ESC   quit (prints the final EDGE_THRESH so you can copy it into
              nms_thresh.v's EDGE_THRESH parameter)
    s         save the current view to a timestamped PNG
"""
import sys
import time
import cv2
import numpy as np

# current hardware value (nms_thresh.v EDGE_THRESH parameter) -- keep this
# in sync by hand if you retune on the board.
DEFAULT_THRESH = 60
MAX_THRESH = 2040   # |Gx|+|Gy| tops out at 4*255*2 for 8-bit input


def fpga_edges(gray, thresh):
    g = gray.astype(np.int32)

    # ---- gaussian_blur3x3.v: [1 2 1; 2 4 2; 1 2 1] / 16, integer ----
    gp = np.pad(g, 1, mode='edge')
    p00, p01, p02 = gp[0:-2, 0:-2], gp[0:-2, 1:-1], gp[0:-2, 2:]
    p10, p11, p12 = gp[1:-1, 0:-2], gp[1:-1, 1:-1], gp[1:-1, 2:]
    p20, p21, p22 = gp[2:,   0:-2], gp[2:,   1:-1], gp[2:,   2:]
    blur = (p00 + 2 * p01 + p02 + 2 * p10 + 4 * p11 + 2 * p12
            + p20 + 2 * p21 + p22) >> 4

    # ---- sobel_edge.v: Gx/Gy, |Gx|+|Gy| magnitude, direction bucket ----
    bp = np.pad(blur, 1, mode='edge')
    b00, b01, b02 = bp[0:-2, 0:-2], bp[0:-2, 1:-1], bp[0:-2, 2:]
    b10,      b12 = bp[1:-1, 0:-2],                bp[1:-1, 2:]
    b20, b21, b22 = bp[2:,   0:-2], bp[2:,   1:-1], bp[2:,   2:]

    gx = (b02 - b00) + 2 * (b12 - b10) + (b22 - b20)
    gy = (b20 + 2 * b21 + b22) - (b00 + 2 * b01 + b02)

    abs_gx = np.abs(gx)
    abs_gy = np.abs(gy)
    magnitude = abs_gx + abs_gy

    gx_dominant = abs_gx >= (abs_gy << 1)
    gy_dominant = abs_gy >= (abs_gx << 1)
    same_sign = (gx >= 0) == (gy >= 0)

    # priority matches sobel_edge.v's dir_code ternary chain exactly:
    # gy_dominant first, then gx_dominant, then pick a diagonal.
    direction = np.where(gy_dominant, 2,
                 np.where(gx_dominant, 0,
                 np.where(same_sign, 1, 3)))

    # ---- nms_thresh.v: suppress non-maxima along the gradient direction ----
    mp = np.pad(magnitude, 1, mode='constant')
    left,  right = mp[1:-1, 0:-2], mp[1:-1, 2:]
    up,    down  = mp[0:-2, 1:-1], mp[2:,   1:-1]
    topright, bottomleft  = mp[0:-2, 2:], mp[2:, 0:-2]
    topleft,  bottomright = mp[0:-2, 0:-2], mp[2:, 2:]

    nbr_a = np.select([direction == 0, direction == 2, direction == 1],
                       [left, up, topright], default=topleft)
    nbr_b = np.select([direction == 0, direction == 2, direction == 1],
                       [right, down, bottomleft], default=bottomright)

    # asymmetric compare -- same tie-break fix as the real nms_thresh.v
    is_local_max = (magnitude > nbr_a) & (magnitude >= nbr_b)
    suppressed = np.where(is_local_max, magnitude, 0)

    edges = (suppressed > thresh).astype(np.uint8) * 255
    return edges


def nothing(_):
    pass


def main():
    cam_index = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    cap = cv2.VideoCapture(cam_index)
    if not cap.isOpened():
        print(f"Couldn't open camera index {cam_index}. Try a different index "
              f"(e.g. `python edge_threshold_tuner.py 1`).")
        sys.exit(1)

    window = "FPGA edge pipeline sim (blur+Sobel+NMS)  q/ESC quit, s save"
    cv2.namedWindow(window, cv2.WINDOW_NORMAL)
    cv2.createTrackbar("EDGE_THRESH", window, DEFAULT_THRESH, MAX_THRESH, nothing)

    print("Camera opened. Drag EDGE_THRESH to taste, 's' to save, 'q'/ESC to quit.")
    print(f"Starting at EDGE_THRESH={DEFAULT_THRESH} (nms_thresh.v's current value).")

    last_thresh = DEFAULT_THRESH
    while True:
        ok, frame = cap.read()
        if not ok:
            print("Failed to read a frame, stopping.")
            break

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        last_thresh = cv2.getTrackbarPos("EDGE_THRESH", window)
        edges = fpga_edges(gray, last_thresh)

        gray_bgr = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
        edges_bgr = cv2.cvtColor(edges, cv2.COLOR_GRAY2BGR)
        for img, label in ((gray_bgr, "Original"),
                            (edges_bgr, f"FPGA sim  EDGE_THRESH={last_thresh}")):
            cv2.putText(img, label, (10, 25), cv2.FONT_HERSHEY_SIMPLEX,
                        0.6, (0, 255, 0), 2, cv2.LINE_AA)

        combined = np.hstack([gray_bgr, edges_bgr])
        cv2.imshow(window, combined)

        key = cv2.waitKey(1) & 0xFF
        if key in (ord('q'), 27):
            break
        elif key == ord('s'):
            fname = f"edge_sim_{int(time.time())}_thresh{last_thresh}.png"
            cv2.imwrite(fname, combined)
            print(f"saved {fname}")

    cap.release()
    cv2.destroyAllWindows()
    print(f"Final EDGE_THRESH={last_thresh} -- copy this into nms_thresh.v's "
          f"EDGE_THRESH parameter if you like it.")


if __name__ == "__main__":
    main()
