"""Evaluate the deployed BNN on photographed handwritten digits.

This script deliberately reproduces roi_binarize_28x28.v before inference:
    luma < 100 -> foreground ink
    each 8x8 block -> 1 if any foreground pixel is present

It does not test Verilog timing.  It tests whether the same model and the
same camera-style preprocessing can recognise the supplied images on a PC.
"""

import argparse
import csv
from pathlib import Path

import numpy as np
from PIL import Image

from export_bnn_v2 import integer_predict


FRAME_WIDTH = 480
FRAME_HEIGHT = 272
ROI_X0 = 128
ROI_Y0 = 24
ROI_SIZE = 224


def find_label(path: Path, root: Path) -> int:
    """Accept samples/2/photo.jpg or samples/2_photo.jpg naming."""
    relative = path.relative_to(root)
    if relative.parts[0] in {str(i) for i in range(10)}:
        return int(relative.parts[0])
    name = path.stem
    if len(name) >= 2 and name[0].isdigit() and name[1] in "_-":
        return int(name[0])
    raise ValueError(
        f"Cannot infer label for {relative}. Put it in a 0...9 folder or name it like 2_example.jpg."
    )


def read_roi(path: Path, mode: str) -> np.ndarray:
    """Return an 8-bit, 224x224 luma ROI."""
    image = Image.open(path).convert("L")
    if mode == "frame480":
        if image.size != (FRAME_WIDTH, FRAME_HEIGHT):
            raise ValueError(
                f"{path}: frame480 mode requires {FRAME_WIDTH}x{FRAME_HEIGHT}, got {image.width}x{image.height}"
            )
        image = image.crop((ROI_X0, ROI_Y0, ROI_X0 + ROI_SIZE, ROI_Y0 + ROI_SIZE))
    else:
        # roi mode accepts a manually cropped digit region of any resolution.
        # It is resized to the same physical 224x224 ROI seen by the FPGA.
        image = image.resize((ROI_SIZE, ROI_SIZE), Image.Resampling.LANCZOS)
    return np.asarray(image, dtype=np.uint8)


def hardware_preprocess(roi: np.ndarray, threshold: int) -> tuple[np.ndarray, int]:
    """Exact 8x8 OR-downsample rule used by roi_binarize_28x28.v."""
    dark = roi < threshold
    bits = dark.reshape(28, 8, 28, 8).any(axis=(1, 3))
    return bits, int(dark.sum())


def save_preview(bits: np.ndarray, path: Path) -> None:
    """Save the actual 28x28 BNN input enlarged with nearest-neighbour pixels."""
    preview = np.where(bits, 0, 255).astype(np.uint8)
    Image.fromarray(preview, mode="L").resize((224, 224), Image.Resampling.NEAREST).save(path)


def write_report(rows: list[dict], out_dir: Path) -> None:
    fields = ["file", "label", "prediction", "correct", "ink_pixels"]
    with (out_dir / "report.csv").open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    confusion = np.zeros((10, 10), dtype=int)
    for row in rows:
        confusion[int(row["label"]), int(row["prediction"])] += 1

    with (out_dir / "report.txt").open("w", encoding="utf-8") as file:
        total = len(rows)
        correct = sum(row["correct"] == 1 for row in rows)
        accuracy = correct / total if total else 0.0
        file.write(f"samples: {total}\ncorrect: {correct}\naccuracy: {accuracy:.2%}\n\n")
        file.write("confusion matrix (row=true label, column=prediction)\n")
        file.write("       " + " ".join(f"{i:4d}" for i in range(10)) + "\n")
        for label in range(10):
            file.write(f"  {label}: " + " ".join(f"{value:4d}" for value in confusion[label]) + "\n")
        file.write("\nper-class accuracy\n")
        for label in range(10):
            count = confusion[label].sum()
            value = confusion[label, label] / count if count else 0.0
            file.write(f"  {label}: {confusion[label, label]}/{count} = {value:.2%}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", type=Path, help="folder containing labelled .jpg/.png images")
    parser.add_argument(
        "--model",
        type=Path,
        default=Path("artifacts/bnn_v2_4x8_export/model_integer.npz"),
        help="integer model exported for the FPGA",
    )
    parser.add_argument(
        "--mode",
        choices=("frame480", "roi"),
        default="roi",
        help="frame480: exact FPGA 480x272 frame; roi: an already-cropped digit ROI",
    )
    parser.add_argument("--threshold", type=int, default=100, help="same dark-pixel threshold as RTL")
    parser.add_argument("--out", type=Path, default=Path("artifacts/camera_bnn_eval"))
    args = parser.parse_args()

    if not 0 <= args.threshold <= 255:
        parser.error("--threshold must be in 0..255")
    if not args.samples.is_dir():
        parser.error(f"sample folder does not exist: {args.samples}")
    if not args.model.is_file():
        parser.error(f"model file does not exist: {args.model}")

    files = sorted(
        path for path in args.samples.rglob("*")
        if path.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"}
    )
    if not files:
        parser.error("no .jpg/.jpeg/.png/.bmp files found")

    args.out.mkdir(parents=True, exist_ok=True)
    preview_dir = args.out / "preprocessed"
    preview_dir.mkdir(exist_ok=True)

    model = dict(np.load(args.model))
    inputs = []
    labels = []
    ink_counts = []
    names = []
    for path in files:
        label = find_label(path, args.samples)
        roi = read_roi(path, args.mode)
        bits, ink_count = hardware_preprocess(roi, args.threshold)
        relative_name = path.relative_to(args.samples).as_posix().replace("/", "__")
        save_preview(bits, preview_dir / f"{Path(relative_name).stem}.png")
        inputs.append(bits.astype(np.float32) * 2.0 - 1.0)
        labels.append(label)
        ink_counts.append(ink_count)
        names.append(path.relative_to(args.samples).as_posix())

    x = np.stack(inputs)[:, None, :, :]
    predictions = integer_predict(x, model)
    rows = [
        {
            "file": name,
            "label": int(label),
            "prediction": int(prediction),
            "correct": int(label == prediction),
            "ink_pixels": ink_count,
        }
        for name, label, prediction, ink_count in zip(names, labels, predictions, ink_counts)
    ]
    write_report(rows, args.out)

    correct = sum(row["correct"] for row in rows)
    print(f"{correct}/{len(rows)} correct = {correct / len(rows):.2%}")
    print(f"report: {args.out / 'report.txt'}")
    print(f"28x28 previews: {preview_dir}")


if __name__ == "__main__":
    main()
