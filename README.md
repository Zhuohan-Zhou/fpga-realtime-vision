# OV5640 FPGA Vision Pipeline

Real-time camera capture and on-chip video processing on a Cyclone IV FPGA — no soft CPU, no OS, just RTL. Camera in, processed video out to an LCD, all in Verilog.

Built during a summer internship as a way to learn video pipeline design and get hands-on with resource-constrained FPGA work.

## Hardware

- **FPGA board:** Alinx AX4010 (Cyclone IV EP4CE10F17C8N — 10,320 LEs / 645 LABs, 46 M9K blocks)
- **Camera:** OV5640 (5MP, DVP interface, configured for YUV422/YUYV output at 480×272)
- **Display:** AN430 LCD panel, 480×272, parallel RGB
- **SDRAM:** W9825G6KH-6, 256Mbit, used as a ping-pong frame buffer
- **Toolchain:** Quartus Prime 25.1 Lite

## What it does

Camera → DVP capture → SDRAM ping-pong buffer → YUV422→RGB888 conversion → LCD, running live at video rate. On top of the base pipeline there's a small set of on-chip image processing blocks, switchable with the board's three user buttons:

| Button | Mode | Status |
|---|---|---|
| KEY3 (default) | Color-threshold blob tracking + motion detection overlay | working |
| KEY2 | Luma threshold binarization | working |
| KEY1 | Sobel edge detection | implemented, temporarily disabled (see below) |

**Color tracking** does per-pixel RGB thresholding, accumulates matching-pixel coordinates over a frame, and divides once per frame (via a small sequential divider) to get a centroid — drawn as a crosshair. EMA smoothing kills frame-to-frame jitter, and once locked on, a search window around the last known position stops same-colored background clutter from stealing the lock.

**Motion detection** splits the frame into 16×16 cells and compares each cell's average luma frame-to-frame (averaging 256 pixels per cell instead of single-pixel sampling knocks sensor/AEC noise down by roughly 16×, which mattered a lot for cutting false positives). Cells with a real change get tinted; a frame only counts as "motion detected" once enough cells agree, so a single noisy cell can't light up on its own.

**Sobel edge detection** is a streaming 3×3 convolution using only adds/subtracts/shifts (no multiplier — Sobel weights are ±1/±2), built with two line buffers for the rolling 3-row window. It's fully written and passes simulation, but currently blows the LAB budget when compiled alongside everything else (858 LABs needed vs. 645 available), so it's commented out of the active build for now rather than half-working. See [`CLAUDE.md`](./CLAUDE.md) for the debugging notes on this.

## Architecture

```
OV5640 --DVP(8b)--> dvp_capture --16b pixel--> pixel_fifo (CDC) --> frame_buffer --> sdram_ctrl (SDRAM)
                                                                          |
                                                                    pixel_fifo (CDC)
                                                                          |
                                                                          v
                                              yuv422_to_rgb888 --RGB888/Y--> [motion_detector + motion_overlay]
                                                                                --> [color_blob_tracker + overlay_marker]
                                                                                --> [mode mux: tracking / binarize / sobel]
                                                                                --> lcd_driver --> AN430 LCD
```

Four clock domains: 50MHz (camera SCCB config), 27MHz (DVP capture), 100MHz (SDRAM), ~9MHz (LCD pixel clock, everything display-side runs here). Clock-domain crossings between the camera and LCD sides go through dual-clock FIFOs plus toggle-flop synchronizers on the frame-pulse signals.

## Project layout

Clock/PLL: `my_pll.v`
Camera config (SCCB): `CameraCapture.v`, `ov5640_init.v`, `ov5640_reg_table.v`
Camera capture (DVP): `dvp_capture.v`
SDRAM / frame buffer: `sdram_ctrl.v`, `pixel_fifo.v`, `frame_buffer.v`
LCD + color conversion: `lcd_driver.v`, `yuv422_to_rgb888.v`
Image processing: `color_blob_tracker.v`, `seq_divider.v`, `overlay_marker.v`, `motion_detector.v`, `motion_overlay.v`, `sobel_edge.v`, `threshold_binarize.v`
Button UI: `button_debounce.v`, `display_mode_select.v`
Top-level: `camera_display_top.v`
SD card (on hold, see below): `sd_spi.v`, `sd_ctrl.v`

Per-module functional writeups live in [`代码模块清单.md`](./代码模块清单.md). Debugging history, pin tables, and gotchas are in [`CLAUDE.md`](./CLAUDE.md).

Every stage also has its own standalone test top-level (`dvp_test_top.v`, `sdram_test_top.v`, `lcd_top.v`, `lcd_pattern_top.v`, `sccb_top_test.v`, `sd_test_top.v`, `cam_init_top.v`) for bringing that piece up in isolation — swap `TOP_LEVEL_ENTITY` in the qsf to use one.

## Building

1. Open `CameraCapture.qpf` in Quartus Prime 25.1 (or compatible).
2. `TOP_LEVEL_ENTITY` is set to `camera_display_top`.
3. Start Compilation.
4. Program the board via JTAG (`CameraCapture.sof` in `output_files/` after build).

Button pins (from the AX4010 manual, Part 13): KEY1=M15, KEY2=M16, KEY3=E16, active-low.

## Current status

- Camera → LCD live video pipeline: done, image quality tuned (AEC targets, saturation, lens correction registers).
- Color tracking + motion detection: done, tested on hardware.
- Threshold binarization + 3-button mode select: done.
- Sobel edge detection: written and simulated, disabled pending a resource fix.
- SD card raw-frame capture: on hold — the SD card used for bring-up has a broken SPI-mode firmware (responds to CMD0/CMD8 but goes silent on CMD55/CMD1); the controller itself implements FatFs-level SPI protocol (real CRC, proper CS/timing handling) and should work once tested against a known-good card.

## Verification approach

No hardware-in-the-loop test framework here — verification is a mix of Quartus RTL simulation, SignalTap for on-hardware signal capture, and Icarus Verilog testbenches for the newer processing modules (color tracking, motion detection, Sobel, button debounce) written during development in an environment without Quartus available.
