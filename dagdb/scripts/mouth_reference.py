#!/usr/bin/env python3
"""Prep-hand reference fixture generator for spec 8 (waveform mouth).

Reproduces the frozen numpy mouth definition from
docs/contracts/SPEC8_MOUTH_GATES_FROZEN.md verbatim, and writes
dagdb/Tests/Fixtures/mouth_reference_v1.json for the engine to bridge against.
"""
import hashlib
import json
import time

import numpy as np


# ---- reference definition (copied verbatim) --------------------------------

def build_bank(T, fs, f0=60.0, H=32, gabor_centers=8, gabor_freqs=6, gabor_sigma_frac=0.02):
    t = np.arange(T) / fs
    cols = []
    for k in range(1, H + 1):
        w = 2 * np.pi * k * f0 * t
        cols.append(np.cos(w)); cols.append(np.sin(w))
    sig = gabor_sigma_frac * T / fs
    for tc in np.linspace(0.1, 0.9, gabor_centers) * T / fs:
        env = np.exp(-0.5 * ((t - tc) / sig) ** 2)
        for f in np.geomspace(f0, fs / 4, gabor_freqs):
            w = 2 * np.pi * f * (t - tc)
            cols.append(env * np.cos(w)); cols.append(env * np.sin(w))
    Phi = np.column_stack(cols).astype(np.float32)
    Phi /= np.linalg.norm(Phi, axis=0, keepdims=True)
    return Phi


def generate(Phi, C): return Phi @ C


def design_probe(Phi, target):
    c, *_ = np.linalg.lstsq(Phi, target, rcond=None)
    return c


# ---- driver ------------------------------------------------------------

def main():
    T = 4096
    fs = 3000.0
    f0 = 60.0
    H = 32
    gc = 8
    gf = 6
    sigma_frac = 0.02

    # 1. Phi
    Phi = build_bank(T, fs, f0=f0, H=H, gabor_centers=gc, gabor_freqs=gf,
                      gabor_sigma_frac=sigma_frac)
    assert Phi.shape == (4096, 160), f"Phi.shape={Phi.shape}"
    assert Phi.dtype == np.float32, f"Phi.dtype={Phi.dtype}"
    K = Phi.shape[1]

    # 2. W = Phi @ C[:, :8]
    C = np.random.default_rng(0).standard_normal((160, 10000)).astype(np.float32)
    W = generate(Phi, C[:, :8])
    assert W.dtype == np.float32, f"W.dtype={W.dtype}"

    # 3. probe
    n = np.arange(T)
    target = (np.sign(np.sin(2 * np.pi * 137 * n / fs))
              * np.exp(-n / T * 3)).astype(np.float32)
    c_ref = design_probe(Phi, target)
    residual_ref = float(np.linalg.norm(Phi @ c_ref - target) / np.linalg.norm(target))

    # 4. white-noise residuals, seeds 0..19
    noise_residuals = []
    for seed in range(20):
        x = np.random.default_rng(seed).standard_normal(T).astype(np.float32)
        c, *_ = np.linalg.lstsq(Phi, x, rcond=None)
        r = float(np.linalg.norm(x - Phi @ c) / np.linalg.norm(x))
        noise_residuals.append(r)
    noise_mean = float(np.mean(noise_residuals))
    noise_min = float(np.min(noise_residuals))
    noise_max = float(np.max(noise_residuals))

    # 5. throughput
    C16 = C[:, :16]
    for _ in range(3):
        generate(Phi, C16)  # warm up
    t0 = time.perf_counter()
    generate(Phi, C)
    dt = time.perf_counter() - t0
    samples_per_second = float(T * 10000 / dt)

    # 6. fixture
    phi_samples = []
    for i in range(256):
        t_i = (997 * i) % T
        k_i = (13 * i) % K
        phi_samples.append({"t": t_i, "k": k_i, "v": float(Phi[t_i, k_i])})

    w_samples = []
    for i in range(256):
        t_i = (997 * i) % T
        m_i = i % 8
        w_samples.append({"t": t_i, "m": m_i, "v": float(W[t_i, m_i])})

    w_frobenius = float(np.linalg.norm(W))

    fixture = {
        "spec": {
            "samples": T,
            "sampleRate": fs,
            "f0": f0,
            "harmonics": H,
            "gaborCenters": gc,
            "gaborFreqs": gf,
            "gaborSigmaFrac": sigma_frac,
        },
        "K": K,
        "phiSamples": phi_samples,
        "cRef": [float(v) for v in C[:, :8].reshape(-1)],
        "wSamples": w_samples,
        "wFrobenius": w_frobenius,
        "probeResidual": residual_ref,
        "probeCoefficients": [float(x) for x in c_ref],
        "noiseResidualMean": noise_mean,
        "noiseResidualMin": noise_min,
        "noiseResidualMax": noise_max,
        "generatedBy": "dagdb/scripts/mouth_reference.py",
        "numpyVersion": np.__version__,
    }

    out_path = "dagdb/Tests/Fixtures/mouth_reference_v1.json"
    with open(out_path, "w") as f:
        json.dump(fixture, f, indent=1)
        f.write("\n")

    with open(out_path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    # Wall-clock timing lives beside the fixture, NOT inside it, so the
    # hashed file is byte-reproducible from the definition alone.
    with open("dagdb/Tests/Fixtures/mouth_reference_v1.timing.json", "w") as f:
        json.dump({"numpySamplesPerSecond": samples_per_second, "note": "one wall-clock timing; not part of the hashed fixture"}, f, indent=1)
    sha_path = "dagdb/Tests/Fixtures/mouth_reference_v1.sha256"
    with open(sha_path, "w") as f:
        f.write(f"{digest}  {out_path.split('/')[-1]}\n")

    import os
    size_bytes = os.path.getsize(out_path)

    print(f"file size: {size_bytes} bytes")
    print(f"probe residual: {residual_ref!r}")
    print(f"noise residual mean/min/max: {noise_mean!r} / {noise_min!r} / {noise_max!r}")
    print(f"samples/s: {samples_per_second!r}")
    print(f"sha256: {digest}")


if __name__ == "__main__":
    main()
