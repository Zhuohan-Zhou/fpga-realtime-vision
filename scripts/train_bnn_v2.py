"""Train the small multi-channel BNN used by the FPGA digit recognizer.

Network: 28x28 binary image -> 3x3 conv(4) -> pool -> 3x3 conv(8) ->
pool -> dense(200, 10).  All weights and activations are +/-1 at inference.
The floating shadow weights exist only while training and are clipped after
every update, which is the BinaryConnect/STE convention.

The input convention intentionally matches roi_binarize_28x28.v:
one means foreground ink, zero means background.  MNIST uses bright strokes,
whereas the camera produces dark strokes; both therefore become foreground=1
after their respective threshold operations.
"""

import argparse
import gzip
import pickle
from pathlib import Path

import numpy as np


RNG = np.random.default_rng(20260722)


def sign(x):
    return np.where(x >= 0, 1.0, -1.0).astype(np.float32)


def binary(x):
    return sign(x)


def conv3(x, w):
    """Valid 3x3 convolution. x is N,C,H,W and w is O,C,3,3."""
    windows = np.lib.stride_tricks.sliding_window_view(x, (3, 3), axis=(2, 3))
    return np.einsum("nchwkl,ockl->nohw", windows, w, optimize=True)


def conv3_backward_input(dout, w, in_shape):
    """Back-propagate through valid convolution; no input gradient is needed for conv1."""
    n, cin, h, width = in_shape
    _, cout, oh, ow = dout.shape
    dx = np.zeros((n, cin, h, width), dtype=np.float32)
    for ky in range(3):
        for kx in range(3):
            dx[:, :, ky:ky + oh, kx:kx + ow] += np.einsum(
                "nohw,oc->nchw", dout, w[:, :, ky, kx], optimize=True
            )
    return dx


def pool2(x):
    """2x2 binary max-pool. Odd final rows/columns are deliberately dropped."""
    n, c, h, width = x.shape
    h2, w2 = h // 2, width // 2
    block = x[:, :, :h2 * 2, :w2 * 2].reshape(n, c, h2, 2, w2, 2)
    return block.max(axis=(3, 5)), block


def pool2_backward(dout, block, original_shape):
    out = block.max(axis=(3, 5))
    winner = block == out[:, :, :, None, :, None]
    count = winner.sum(axis=(3, 5), keepdims=True)
    grad_block = winner * dout[:, :, :, None, :, None] / count
    dx = np.zeros(original_shape, dtype=np.float32)
    h2, w2 = out.shape[2:]
    dx[:, :, :h2 * 2, :w2 * 2] = grad_block.reshape(
        original_shape[0], original_shape[1], h2 * 2, w2 * 2
    )
    return dx


class Bnn:
    def __init__(self, c1=4, c2=8):
        self.c1 = c1
        self.c2 = c2
        self.w1 = RNG.normal(0, 0.25, (c1, 1, 3, 3)).astype(np.float32)
        self.w2 = RNG.normal(0, 0.25, (c2, c1, 3, 3)).astype(np.float32)
        self.wd = RNG.normal(0, 0.15, (c2 * 5 * 5, 10)).astype(np.float32)
        self.t1 = np.zeros(c1, dtype=np.float32)
        self.t2 = np.zeros(c2, dtype=np.float32)
        self.bd = np.zeros(10, dtype=np.float32)
        self.step = 0
        self.m = {name: np.zeros_like(getattr(self, name)) for name in ("w1", "w2", "wd", "t1", "t2", "bd")}
        self.v = {name: np.zeros_like(getattr(self, name)) for name in ("w1", "w2", "wd", "t1", "t2", "bd")}

    def adam(self, name, grad, lr):
        self.m[name] = 0.9 * self.m[name] + 0.1 * grad
        self.v[name] = 0.999 * self.v[name] + 0.001 * grad * grad
        m_hat = self.m[name] / (1.0 - 0.9 ** self.step)
        v_hat = self.v[name] / (1.0 - 0.999 ** self.step)
        value = getattr(self, name) - lr * m_hat / (np.sqrt(v_hat) + 1e-8)
        if name.startswith("w"):
            value = np.clip(value, -1.0, 1.0)
        setattr(self, name, value)

    def forward(self, x):
        w1b, w2b, wdb = binary(self.w1), binary(self.w2), binary(self.wd)
        pre1 = conv3(x, w1b)
        a1 = sign(pre1 - self.t1[None, :, None, None])
        p1, p1_block = pool2(a1)
        pre2 = conv3(p1, w2b)
        a2 = sign(pre2 - self.t2[None, :, None, None])
        p2, p2_block = pool2(a2)
        flat = p2.reshape(len(x), -1)
        logits = flat @ wdb + self.bd
        cache = (x, w1b, pre1, a1, p1, p1_block, w2b, pre2, a2, p2_block, flat, wdb)
        return logits, cache

    def train_batch(self, x, labels, lr):
        self.step += 1
        logits, cache = self.forward(x)
        probs = np.exp(logits - logits.max(axis=1, keepdims=True))
        probs /= probs.sum(axis=1, keepdims=True)
        probs[np.arange(len(labels)), labels] -= 1.0
        dlogits = probs / len(labels)

        x0, w1b, pre1, a1, p1, p1_block, w2b, pre2, a2, p2_block, flat, wdb = cache
        grad_wd = flat.T @ dlogits
        grad_bd = dlogits.sum(axis=0)
        dp2 = (dlogits @ wdb.T).reshape(-1, self.c2, 5, 5)
        da2 = pool2_backward(dp2, p2_block, a2.shape)
        dpre2 = da2 * (np.abs(pre2 - self.t2[None, :, None, None]) <= 1.0)
        p1_windows = np.lib.stride_tricks.sliding_window_view(p1, (3, 3), axis=(2, 3))
        grad_w2 = np.einsum("nohw,nchwkl->ockl", dpre2, p1_windows, optimize=True)
        grad_t2 = -dpre2.sum(axis=(0, 2, 3))
        dp1 = conv3_backward_input(dpre2, w2b, p1.shape)
        da1 = pool2_backward(dp1, p1_block, a1.shape)
        dpre1 = da1 * (np.abs(pre1 - self.t1[None, :, None, None]) <= 1.0)
        x_windows = np.lib.stride_tricks.sliding_window_view(x0, (3, 3), axis=(2, 3))
        grad_w1 = np.einsum("nohw,nchwkl->ockl", dpre1, x_windows, optimize=True)
        grad_t1 = -dpre1.sum(axis=(0, 2, 3))

        self.adam("w1", grad_w1, lr)
        self.adam("w2", grad_w2, lr)
        self.adam("wd", grad_wd, lr)
        self.adam("t1", grad_t1, lr)
        self.adam("t2", grad_t2, lr)
        self.adam("bd", grad_bd, lr)
        return (logits.argmax(axis=1) == labels).mean()

    def accuracy(self, x, labels, batch=256):
        correct = 0
        for start in range(0, len(x), batch):
            logits, _ = self.forward(x[start:start + batch])
            correct += (logits.argmax(axis=1) == labels[start:start + batch]).sum()
        return correct / len(labels)

    def save(self, path):
        np.savez(
            path,
            w1=binary(self.w1).astype(np.int8), w2=binary(self.w2).astype(np.int8),
            wd=binary(self.wd).astype(np.int8), t1=self.t1, t2=self.t2, bd=self.bd,
            shadow_w1=self.w1, shadow_w2=self.w2, shadow_wd=self.wd,
            c1=self.c1, c2=self.c2, input_foreground_one=True,
        )


def load_mnist(path):
    with gzip.open(path, "rb") as file:
        train, valid, test = pickle.load(file, encoding="latin1")

    def prepare(split):
        pixels, labels = split
        foreground = (pixels.reshape(-1, 1, 28, 28) > 0.5).astype(np.float32)
        return foreground * 2.0 - 1.0, labels.astype(np.int64)

    return prepare(train), prepare(valid), prepare(test)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mnist", type=Path, help="path to mnist.pkl.gz")
    parser.add_argument("--epochs", type=int, default=25)
    parser.add_argument("--batch", type=int, default=128)
    parser.add_argument("--lr", type=float, default=0.001)
    parser.add_argument("--decay-every", type=int, default=10)
    parser.add_argument("--decay-factor", type=float, default=0.5)
    parser.add_argument("--c1", type=int, default=4)
    parser.add_argument("--c2", type=int, default=8)
    parser.add_argument("--out", type=Path, default=Path("artifacts/bnn_v2.npz"))
    args = parser.parse_args()

    (x_train, y_train), (x_valid, y_valid), (x_test, y_test) = load_mnist(args.mnist)
    model = Bnn(args.c1, args.c2)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    best = 0.0

    for epoch in range(args.epochs):
        order = RNG.permutation(len(x_train))
        lr = args.lr * args.decay_factor ** (epoch // args.decay_every)
        for start in range(0, len(order), args.batch):
            idx = order[start:start + args.batch]
            model.train_batch(x_train[idx], y_train[idx], lr)
        valid = model.accuracy(x_valid, y_valid)
        print(f"epoch {epoch + 1:02d}: lr={lr:.5f}, validation={valid:.2%}")
        if valid > best:
            best = valid
            model.save(args.out)

    saved = np.load(args.out)
    best_model = Bnn(int(saved["c1"]), int(saved["c2"]))
    best_model.w1, best_model.w2, best_model.wd = saved["w1"], saved["w2"], saved["wd"]
    best_model.t1, best_model.t2, best_model.bd = saved["t1"], saved["t2"], saved["bd"]
    print(f"best validation={best:.2%}, test={best_model.accuracy(x_test, y_test):.2%}")


if __name__ == "__main__":
    main()
