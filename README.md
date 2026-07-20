# OV5640 FPGA Vision Pipeline

## Abstract / goal

A real-time camera-to-display vision pipeline built entirely in Verilog on a small Cyclone IV FPGA — no soft CPU, no OS, no external accelerator. Camera in, live video out to an LCD, with a handful of on-chip image-processing algorithms layered on top and switchable at runtime with the board's buttons.

The project has two goals:

1. **Prove a resource-constrained FPGA (10,320 logic elements) can host a full video pipeline plus several vision algorithms at once** — DVP camera capture, an SDRAM ping-pong frame buffer, color-space conversion, edge detection, color-blob tracking with Kalman filtering, and 1D barcode (EAN-13/UPC-A) decoding, all running live off the camera feed.
2. **Prove the same chip can run a real CNN with zero multipliers**, using a from-scratch-trained binarized neural network (BNN) for handwritten-digit recognition (XNOR + popcount instead of multiply-accumulate). This runs as a background classifier reading a fixed region of the camera frame and driving the board's 7-segment digital tube — independent of the buttons above.

Built during a summer internship as a way to learn video pipeline design and get hands-on with resource-constrained FPGA work.

## Hardware

- **FPGA board:** Alinx AX4010 (Cyclone IV EP4CE10F17C8N — 10,320 LEs / 645 LABs, 46 M9K blocks, 15 hardware 18×18 multipliers)
- **Camera:** OV5640 (5MP, DVP interface, configured for YUV422/YUYV output at 480×272)
- **Display:** AN430 LCD panel, 480×272, parallel RGB
- **SDRAM:** W9825G6KH-6, 256Mbit, used as a ping-pong frame buffer
- **Other on-board I/O used:** 3 user buttons (mode select), 4 LEDs, 6-digit digital tube (BNN result display), microSD slot (paused, see below)
- **Toolchain:** Quartus Prime 25.1 Lite

## What it does

Camera → DVP capture → SDRAM ping-pong buffer → YUV422→RGB888 conversion → LCD, running live at video rate. Two independent feature layers sit on top of that base pipeline:

**Three buttons switch which processed view is shown on the LCD:**

| Button | Mode | Status |
|---|---|---|
| KEY3 (default) | Color-threshold blob tracking, Kalman-filtered, drawn as a crosshair | Simulated — not yet re-verified on hardware after the Kalman rewrite |
| KEY2 | EAN-13 / UPC-A barcode decoding (reads retail product barcodes off a fixed scan line) | Simulated — not yet verified on hardware |
| KEY1 | Sobel edge detection (Gaussian blur → gradient → non-max suppression) | Simulated; a resource-usage bug that used to make this blow the LAB budget has been fixed in RTL, pending a recompile to confirm |

**A fourth feature runs in the background regardless of button state:** a green box is drawn on the LCD marking a fixed 224×224 region of the frame; whatever's inside it is downsampled to 28×28, classified 0–9 by the on-chip BNN, and the digit is shown on the board's digital tube. The BNN math itself is hardware-verified (see [Current status](#current-status)); the full camera-to-digital-tube wiring has been flashed once, with several bugs found and fixed, and the latest fix is still pending a hardware re-check.

## Architecture

```
OV5640 --DVP(8b)--> dvp_capture --16b pixel--> pixel_fifo (CDC) --> frame_buffer --> sdram_ctrl (SDRAM)
                                                                          |
                                                                    pixel_fifo (CDC)
                                                                          |
                                                                          v
                                              yuv422_to_rgb888 --RGB888 + Y8-->
                                                                          |
                        +-----------------------------------------------+------------------------------------------+
                        |                                               |                                          |
                  [mode mux, KEY1/2/3]                          [BNN branch, always on]                  [ROI box overlay]
                        |                                               |                                          |
        +---------------+---------------+                 roi_binarize_28x28 --28x28-->             draws green box on LCD
        |               |               |                       bnn_core --digit-->                  around the BNN's ROI
  gaussian_blur3x3  ean13_decoder  color_blob_tracker           seg7_decoder --> digital tube
   -> sobel_edge    (scan line)    + kalman_1d x2
   -> nms_thresh                   -> overlay_marker
        |               |               |
        +---------------+---------------+
                        |
                        v
                  lcd_driver --> AN430 LCD
```

Clock domains: 50MHz (camera SCCB config), 24MHz (camera XCLK), 100MHz (SDRAM), ~8.955MHz (LCD pixel clock — everything display-side, including all vision/BNN modules, runs here). Clock-domain crossings between the camera and LCD sides go through dual-clock FIFOs plus toggle-flop synchronizers on the frame-pulse signals.

## Project structure

### Quartus project control (root, don't move — Quartus expects these paths)
| File | Responsibility |
|---|---|
| `CameraCapture.qpf` | Quartus project file |
| `CameraCapture.qsf` | Pin assignments, list of source files to compile, and which module is `TOP_LEVEL_ENTITY` |
| `CameraCapture.sdc` / `lcd_top.sdc` / `sccb_top_test.sdc` | Timing constraints for the main build and for two of the standalone test tops |
| `stp1.stp` | SignalTap on-chip logic analyzer configuration |

### Clock generation
| File | Responsibility |
|---|---|
| `my_pll.v` | Hand-written `altpll` instantiation — one 50MHz input, four output clocks |

### Camera bring-up (SCCB / register init)
| File | Responsibility |
|---|---|
| `CameraCapture.v` | Low-level SCCB (I2C-like) byte-write engine |
| `ov5640_init.v` | Power-up/reset sequencer that walks the full register table on boot |
| `ov5640_reg_table.v` | 253-entry ROM of OV5640 register writes (YUV422 output mode, AEC/AGC, AWB, gamma, lens correction, mirror/flip, etc.) |
| `cam_init_top.v`, `sccb_top_test.v` | Standalone test tops for bringing up the camera link in isolation |

### Camera capture (DVP)
| File | Responsibility |
|---|---|
| `dvp_capture.v` | Captures DVP byte pairs into 16-bit pixels, aligned to HREF/VSYNC |
| `dvp_test_top.v` | Standalone test top |

### SDRAM frame buffer
| File | Responsibility |
|---|---|
| `sdram_ctrl.v` | W9825G6KH SDRAM controller — burst-4, CL2 @ 100MHz, ping-pong banks |
| `pixel_fifo.v` | Dual-clock FIFO (`dcfifo`) crossing between camera and SDRAM/LCD clock domains |
| `frame_buffer.v` | Ping-pong scheduling logic across the two FIFOs |
| `sdram_test_top.v` | Standalone test top |

### LCD display
| File | Responsibility |
|---|---|
| `lcd_driver.v` | AN430 timing generator (HS/VS/DE) — also where the RGB bit-order correction for the board's wiring lives |
| `yuv422_to_rgb888.v` | Fixed-point BT.601 YUV422→RGB888 conversion, plus a passthrough luma (`y8`) output for the vision modules |
| `lcd_top.v`, `lcd_pattern_top.v` | Standalone LCD test tops (solid colors / test patterns, no camera needed) |

### Main integration
| File | Responsibility |
|---|---|
| `camera_display_top.v` | The real `TOP_LEVEL_ENTITY` — wires the base pipeline together with every feature module below |

### Vision mode — Sobel edge detection (KEY1)
| File | Responsibility |
|---|---|
| `gaussian_blur3x3.v` | 3×3 blur pre-filter (noise reduction before edge detection) |
| `sobel_edge.v` | Streaming 3×3 Sobel convolution — outputs gradient magnitude + direction, no multipliers (weights are ±1/±2, done with shifts/adds) |
| `nms_thresh.v` | Non-maximum suppression + threshold, so edges come out 1px wide instead of a blurry band |

### Vision mode — Barcode decoding (KEY2)
| File | Responsibility |
|---|---|
| `ean13_decoder.v` | **Active.** EAN-13/UPC-A decoder — the format printed on real retail packaging |
| `barcode_decoder.v` | **Disabled** (qsf line commented out). Earlier Code 39 decoder; kept for reference, not retail-barcode compatible |
| `threshold_binarize.v` | **Disabled.** Even earlier luma-threshold black/white mode, superseded by barcode decoding |

### Vision mode — Centroid tracking (KEY3, default)
| File | Responsibility |
|---|---|
| `color_blob_tracker.v` | Per-pixel color thresholding → centroid, gated against a Kalman-filtered prediction so the lock can't get yanked onto a same-colored distractor |
| `kalman_1d.v` | 1D steady-state ("alpha-beta") Kalman filter — one instance each for X and Y |
| `overlay_marker.v` | Draws the crosshair at the tracked position |
| `motion_detector.v`, `motion_overlay.v` | **Disabled.** Per-cell frame-to-frame motion detection, removed from the top level but kept in the repo — uncomment in the qsf to bring back |

### Mode-selection UI
| File | Responsibility |
|---|---|
| `button_debounce.v` | Debounces KEY1/KEY2/KEY3 |
| `display_mode_select.v` | Picks which processed stream drives the LCD based on button state |

### Background digit recognition (BNN) — always running, independent of the 3 buttons
| File | Responsibility |
|---|---|
| `roi_binarize_28x28.v` | Crops a fixed 224×224 region from the center of the frame and downsamples it to a 28×28 binary image; also flags whether there's enough "ink" present to bother classifying |
| `bnn_core.v` | The binarized CNN itself — two conv+pool stages and a dense layer, entirely XNOR + popcount, zero multipliers |
| `seg7_decoder.v` | Converts the classified digit (0–9) into a 7-segment display pattern |
| `bnn_demo_top.v` | Standalone test top — cycles through 7 hardcoded MNIST test images via KEY1 and shows the result on the 4 LEDs. **This is the one hardware-verified end-to-end BNN test** (see status below) |

### SD card (paused — waiting for a working card)
| File | Responsibility |
|---|---|
| `sd_spi.v` | SPI byte transceiver |
| `sd_ctrl.v` | SD card init/command state machine (FatFs-level SPI protocol: real CRC, proper CS/timing) |
| `sd_test_top.v` | Standalone test top |
| `sd_dump.py` | Host-side script to pull a captured raw frame off the card and convert it to PNG |

### Simulation
| Path | Responsibility |
|---|---|
| `testbench/` | Icarus Verilog testbenches: `tb_barcode_decoder.v`, `tb_bnn_core.v`, `tb_bnn_demo_top.v`, `tb_ean13_decoder.v`, `tb_roi_binarize_28x28.v`, `tb_seg7_decoder.v` |

### Offline tooling (Python, run on a PC, not synthesized)
| File | Responsibility |
|---|---|
| `edge_threshold_tuner.py` | Interactive Sobel/edge threshold tuning using a PC webcam, before committing values to RTL |
| `opencv_edge_compare.py` | Compares the FPGA's Sobel output against an OpenCV reference implementation |

### Reference material
| File | Responsibility |
|---|---|
| `Alinx AX4010 User Manual.pdf` | Board manual — pin tables, digital tube wiring, connector pinouts |
| `CNN in tiny FPGAs.pdf` | Background reading for the BNN sub-project |
| `FPGA运动目标检测跟踪系统.pdf` | Background reading for the tracking/motion-detection work |

### Docs
| File | Responsibility |
|---|---|
| `README.md` | This file — structure and current status |
| `CLAUDE.md` | Full project memory: every design decision, bug, root cause, and fix, in chronological order, plus the exact pin table and chip resource numbers. Read this for **why** something is built the way it is, and for what's still pending hardware verification |

### Quartus-managed (gitignored — regenerated by every compile, never hand-edit)
`db/`, `incremental_db/`, `output_files/`, `simulation/`, `.qsys_edit/`

## Building

1. Open `CameraCapture.qpf` in Quartus Prime 25.1 (or compatible).
2. `TOP_LEVEL_ENTITY` is set to `camera_display_top`.
3. Start Compilation.
4. Program the board via JTAG (`CameraCapture.sof` appears in `output_files/` after a build).

Every pipeline stage also has its own standalone test top-level (`dvp_test_top.v`, `sdram_test_top.v`, `lcd_top.v`, `lcd_pattern_top.v`, `sccb_top_test.v`, `sd_test_top.v`, `cam_init_top.v`, `bnn_demo_top.v`) for bringing that piece up in isolation — swap `TOP_LEVEL_ENTITY` in the qsf to use one. Exact pin numbers for every peripheral (camera, LCD, SDRAM, SD, buttons, LEDs, digital tube) are in `CLAUDE.md`.

## Current status

| Feature | Status |
|---|---|
| Camera → SDRAM → LCD live video | **Verified on hardware.** Image quality tuned (AEC targets, saturation, lens correction), user-confirmed |
| KEY3 — Kalman-filtered centroid tracking | Simulated only — the Kalman-filter rewrite hasn't been compiled/flashed yet |
| KEY2 — EAN-13/UPC-A barcode decoding | Simulated only — not yet compiled/flashed |
| KEY1 — Sobel edge detection (blur + NMS) | Simulated; previously blew the LAB budget (858 vs. 645 available) due to a combinational-memory-read bug, which has been fixed in RTL — pending a recompile to confirm the fix actually brings LAB usage back under budget |
| Background BNN digit recognition — core classifier | **Verified on hardware**, standalone (`bnn_demo_top.v`): known test images classify correctly, including a known misclassification that reproduces identically on real silicon — strong evidence the RTL matches the trained model bit-for-bit |
| Background BNN digit recognition — full camera integration | Compiled and flashed once; three bugs found on hardware and fixed (blank-frame false digit display, mirrored camera image, missing ROI viewfinder box), plus one more bug found after that (digital-tube segment wiring was in the wrong bit order, also fixed) — the latest fix has not yet been re-verified on hardware |
| SD card raw-frame capture | Paused. Controller is implemented correctly (FatFs-level SPI protocol); the specific SD card used for bring-up has broken SPI-mode firmware and needs to be swapped for a known-good card |
| Motion detection / Code 39 barcode / luma binarize | Disabled — superseded by newer modes, code kept in the repo, qsf lines commented out |

## Chip resource usage

EP4CE10F17C8N: 10,320 LEs (645 LABs), 46 M9K blocks (~424 Kbit on-chip RAM), 15 hardware 18×18 multipliers.

- Every algorithm in this project — Sobel, NMS, Kalman filtering, EAN-13 decoding, and the BNN itself — is built entirely from shifts, adds, and comparisons. **Zero hardware multipliers are used anywhere**, so all 15 are free headroom for anything added later that needs real multiplication (e.g. non-approximate filtering).
- The BNN core alone measured **~2,860 LEs (~28% of the chip)** in a standalone synthesis run (`bnn_demo_top` as top-level).
- The combined resource usage with the full pipeline (video + all three vision modes + BNN) compiled together has **not yet been measured** — confirming everything fits together is the next compile's job.

## Next steps

1. Recompile with everything enabled and confirm LAB/LE usage fits (Sobel's fix, in particular, needs this check).
2. Flash and hardware-verify: Kalman tracking, EAN-13 decoding, and the latest BNN/digital-tube fix.
3. Resolve the camera's fixed manual focus — several modes (BNN digit recognition especially) need a properly focused image to be meaningfully testable.
4. Swap in a known-good SD card to resume raw-frame capture.

See `CLAUDE.md` for the full history behind each of these.
