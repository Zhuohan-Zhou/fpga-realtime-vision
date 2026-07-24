"""Export a trained BNN to small, reviewable FPGA memory files.

The FPGA never needs floating-point thresholds. A convolution sum is an
integer, so sign(sum - threshold) is exactly represented by sum >= ceil(threshold).
"""

import argparse
from pathlib import Path

import numpy as np

from train_bnn_v2 import conv3, load_mnist, pool2, sign


def write_bits(path, weights):
    rows = weights.reshape(weights.shape[0], -1)
    with path.open("w", encoding="ascii") as file:
        for row in rows:
            file.write("".join("1" if bit > 0 else "0" for bit in row) + "\n")


def integer_predict(x, model):
    w1 = model["w1"].astype(np.float32)
    w2 = model["w2"].astype(np.float32)
    wd = model["wd"].astype(np.float32)
    cut1 = model["cut1"]
    cut2 = model["cut2"]
    bias = model["dense_bias"]

    a1 = np.where(conv3(x, w1) >= cut1[None, :, None, None], 1.0, -1.0)
    p1, _ = pool2(a1)
    a2 = np.where(conv3(p1, w2) >= cut2[None, :, None, None], 1.0, -1.0)
    p2, _ = pool2(a2)
    return (p2.reshape(len(x), -1) @ wd + bias).argmax(axis=1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model", type=Path)
    parser.add_argument("--out", type=Path, default=Path("artifacts/bnn_v2_export"))
    parser.add_argument("--mnist", type=Path, help="optional: report integer test accuracy")
    args = parser.parse_args()

    raw = np.load(args.model)
    export = {
        "w1": raw["w1"],
        "w2": raw["w2"],
        "wd": raw["wd"],
        "cut1": np.ceil(raw["t1"]).astype(np.int16),
        "cut2": np.ceil(raw["t2"]).astype(np.int16),
        "dense_bias": np.rint(raw["bd"]).astype(np.int16),
        "c1": raw["c1"],
        "c2": raw["c2"],
    }
    args.out.mkdir(parents=True, exist_ok=True)
    np.savez(args.out / "model_integer.npz", **export)
    write_bits(args.out / "conv1.mem", export["w1"])
    write_bits(args.out / "conv2.mem", export["w2"])
    write_bits(args.out / "dense.mem", export["wd"].T)

    with (args.out / "manifest.txt").open("w", encoding="ascii") as file:
        file.write("input: 28x28, foreground ink=1\n")
        file.write(f"conv1: {int(export['c1'])} filters, 3x3, cuts={export['cut1'].tolist()}\n")
        file.write(f"conv2: {int(export['c2'])} filters, 3x3, cuts={export['cut2'].tolist()}\n")
        file.write(f"dense: {int(export['c2']) * 25} inputs, 10 outputs, bias={export['dense_bias'].tolist()}\n")

    if args.mnist:
        _, _, (x_test, y_test) = load_mnist(args.mnist)
        accuracy = (integer_predict(x_test, export) == y_test).mean()
        print(f"integer test accuracy={accuracy:.2%}")


if __name__ == "__main__":
    main()
