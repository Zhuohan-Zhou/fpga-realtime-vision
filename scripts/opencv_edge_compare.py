import sys
import time
import cv2
import numpy as np


def sobel_fpga_like(gray, blur_ksize, sobel_thresh):
    blurred = cv2.GaussianBlur(gray, (blur_ksize, blur_ksize), 0)
    gx = cv2.Sobel(blurred, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(blurred, cv2.CV_32F, 0, 1, ksize=3)
    magnitude = np.abs(gx) + np.abs(gy)
    edges = (magnitude > sobel_thresh).astype(np.uint8) * 255
    return edges


def nothing(_):
    pass


def main():
    cam_index = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    cap = cv2.VideoCapture(cam_index)
    if not cap.isOpened():
        print(f"Couldn't open camera index {cam_index}. Try a different index "
              f"(e.g. `python opencv_edge_compare.py 1`).")
        sys.exit(1)

    window = "Edge detection comparison  (q/ESC quit, s save)"
    cv2.namedWindow(window, cv2.WINDOW_NORMAL)

    # Sobel threshold: same scale as the FPGA's EDGE_THRESH (0..~2040,
    # since |Gx|+|Gy| tops out at 4*255*2 for 8-bit input). Default here
    # matches sobel_edge.v's current tuned value.
    cv2.createTrackbar("Sobel thresh", window, 90, 2040, nothing)
    # Canny's two thresholds (OpenCV convention: edges with gradient above
    # the high threshold are "sure edges"; the low threshold is the floor
    # below which hysteresis won't even consider a pixel).
    cv2.createTrackbar("Canny low", window, 50, 500, nothing)
    cv2.createTrackbar("Canny high", window, 150, 500, nothing)

    print("Camera opened. Adjust the trackbars, press 's' to save a comparison "
          "frame, 'q' or ESC to quit.")

    while True:
        ok, frame = cap.read()
        if not ok:
            print("Failed to read a frame, stopping.")
            break

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

        sobel_thresh = cv2.getTrackbarPos("Sobel thresh", window)
        canny_low = cv2.getTrackbarPos("Canny low", window)
        canny_high = cv2.getTrackbarPos("Canny high", window)

        sobel_edges = sobel_fpga_like(gray, blur_ksize=3, sobel_thresh=sobel_thresh)
        canny_edges = cv2.Canny(gray, canny_low, canny_high)

        # stack three grayscale panels side by side, each labeled
        gray_bgr = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
        sobel_bgr = cv2.cvtColor(sobel_edges, cv2.COLOR_GRAY2BGR)
        canny_bgr = cv2.cvtColor(canny_edges, cv2.COLOR_GRAY2BGR)

        for img, label in ((gray_bgr, "Original"),
                            (sobel_bgr, "Sobel (FPGA-like, threshold only)"),
                            (canny_bgr, "Canny (blur+Sobel+NMS+hysteresis)")):
            cv2.putText(img, label, (10, 25), cv2.FONT_HERSHEY_SIMPLEX,
                        0.6, (0, 255, 0), 2, cv2.LINE_AA)

        combined = np.hstack([gray_bgr, sobel_bgr, canny_bgr])
        cv2.imshow(window, combined)

        key = cv2.waitKey(1) & 0xFF
        if key in (ord('q'), 27):  # q or ESC
            break
        elif key == ord('s'):
            fname = f"edge_compare_{int(time.time())}.png"
            cv2.imwrite(fname, combined)
            print(f"saved {fname}")

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
