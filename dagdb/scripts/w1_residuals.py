#!/usr/bin/env python3
"""Prep hand for docs/contracts/KERNELS_GATES_FROZEN.md.

Computes the frozen cross-convolution residual R for every trial in the
sealed W1 records against the sealed W1 kernels, reproduces the court's
gate lines (G0..G3, cal reference), and writes the residual fixture
dagdb/Tests/Fixtures/w1_residuals_v1.json plus a byte-identical copy of
the sealed kernels file with sha256 sidecars for both.

Sealed inputs are treated as data, not touched.
"""

import hashlib
import json
import time
from pathlib import Path

import numpy as np

KERNELS_SRC = Path(
    "<fixtures>/"  # set to your fixture root
    "w1_kernels.json"
)
RECORDS_SRC = Path(
    "<fixtures>/"  # set to your fixture root
    "w1_records.json"
)

KERNELS_SHA = "2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8"
RECORDS_SHA = "ba899eeff82a85b74ce5572d8a5297eee479d9eb4b72b11ea0add2359f633f1a"

REPO_ROOT = Path(__file__).resolve().parents[2]  # the repository root
FIXTURES = REPO_ROOT / "dagdb" / "Tests" / "Fixtures"

WARM = 185
TOL = 1.00452e-2
TOL0 = 2.533e-14

FORMULA_LINES = [
    'yAB = np.convolve(kB, a, mode="full")[:n]',
    'yBA = np.convolve(kA, b, mode="full")[:n]',
    "w = slice(WARM, n)",
    "R = np.abs(yAB[w] - yBA[w]).max() / (np.abs(yAB[w]).max() + 1e-300)",
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_sealed():
    for path, expected in ((KERNELS_SRC, KERNELS_SHA), (RECORDS_SRC, RECORDS_SHA)):
        if not path.exists():
            raise SystemExit(f"STOP: sealed input missing: {path}")
        got = sha256_file(path)
        if got != expected:
            raise SystemExit(
                f"STOP: sha256 mismatch for {path}\n  expected {expected}\n  got      {got}"
            )
        print(f"sha256 OK: {path.name} = {got}")


def compute_R(a, b, kA, kB, n, warm):
    yAB = np.convolve(kB, a, mode="full")[:n]
    yBA = np.convolve(kA, b, mode="full")[:n]
    w = slice(warm, n)
    R = np.abs(yAB[w] - yBA[w]).max() / (np.abs(yAB[w]).max() + 1e-300)
    return R, yAB, yBA


def compute_R_fullwin(a, b, kA, kB, n, warm):
    yAB = np.convolve(kB, a, mode="full")
    yBA = np.convolve(kA, b, mode="full")
    m = len(kB)  # kA and kB share length (2048) per the sealed kernels
    w = slice(warm, n + m - 1)
    R = np.abs(yAB[w] - yBA[w]).max() / (np.abs(yAB[w]).max() + 1e-300)
    return R


def compute_R_symden(a, b, kA, kB, n, warm):
    yAB = np.convolve(kB, a, mode="full")[:n]
    yBA = np.convolve(kA, b, mode="full")[:n]
    w = slice(warm, n)
    denom = max(np.abs(yAB[w]).max(), np.abs(yBA[w]).max()) + 1e-300
    R = np.abs(yAB[w] - yBA[w]).max() / denom
    return R


def compute_R_f32(a, b, kA, kB, n, warm):
    a32 = np.asarray(a, np.float32)
    b32 = np.asarray(b, np.float32)
    kA32 = np.asarray(kA, np.float32)
    kB32 = np.asarray(kB, np.float32)
    # convolution in float64 of the float32-cast values, then sealed formula
    yAB = np.convolve(kB32.astype(np.float64), a32.astype(np.float64), mode="full")[:n]
    yBA = np.convolve(kA32.astype(np.float64), b32.astype(np.float64), mode="full")[:n]
    w = slice(warm, n)
    R = np.abs(yAB[w] - yBA[w]).max() / (np.abs(yAB[w]).max() + 1e-300)
    return R


def run():
    t_start = time.time()
    print(f"start {time.strftime('%Y-%m-%d %H:%M:%S')}")

    verify_sealed()

    kernels = json.load(open(KERNELS_SRC))
    records = json.load(open(RECORDS_SRC))

    kA = np.asarray(kernels["kA"], float)
    kB = np.asarray(kernels["kB"], float)

    trial_keys = list(records.keys())  # preserve records' key order
    count = len(trial_keys)
    print(f"trial count (counted, not assumed): {count}")

    trials_out = {}
    R_by_key = {}

    for key in trial_keys:
        rec = records[key]
        a = np.asarray(rec["a"], float)
        b = np.asarray(rec["b"], float)
        n = len(a)
        assert n == 2048, f"{key}: n={n} != 2048"
        assert len(b) == 2048, f"{key}: len(b)={len(b)} != 2048"

        R, _, _ = compute_R(a, b, kA, kB, n, WARM)
        R_fullwin = compute_R_fullwin(a, b, kA, kB, n, WARM)
        R_symden = compute_R_symden(a, b, kA, kB, n, WARM)
        R_f32 = compute_R_f32(a, b, kA, kB, n, WARM)

        R_by_key[key] = float(R)
        trials_out[key] = {
            "class": rec["class"],
            "R": float(R),
            "R_fullwin": float(R_fullwin),
            "R_symden": float(R_symden),
            "R_f32": float(R_f32),
        }

    # --- reproduce the court's lines ---
    def is_class(key, cls):
        return trials_out[key]["class"] == cls

    cal0_keys = [k for k in trial_keys if is_class(k, "cal0")]
    cal_keys = [k for k in trial_keys if is_class(k, "cal")]
    court_keys = [k for k in trial_keys if is_class(k, "court")]
    fake_keys = [k for k in trial_keys if is_class(k, "fake")]
    pert_keys = [k for k in trial_keys if is_class(k, "pert")]

    print(
        f"class counts: cal0={len(cal0_keys)} cal={len(cal_keys)} "
        f"court={len(court_keys)} fake={len(fake_keys)} pert={len(pert_keys)}"
    )

    # G0: cal0 entry whose numeric part is "1"
    g0_key = None
    for k in cal0_keys:
        numeric_part = k.split("_", 1)[1] if "_" in k else k
        if numeric_part == "1":
            g0_key = k
            break
    assert g0_key is not None, "no cal0 entry with numeric part '1' found"
    G0 = R_by_key[g0_key]

    # G1: worst court R, and count of court trials with R <= TOL
    court_Rs = [R_by_key[k] for k in court_keys]
    G1_worst = max(court_Rs)
    G1_within = sum(1 for r in court_Rs if r <= TOL)

    # G2: count of fake trials with R > 10*TOL, strict
    fake_Rs = [R_by_key[k] for k in fake_keys]
    G2_flares = sum(1 for r in fake_Rs if r > 10 * TOL)

    # G3: count of pert trials with R > TOL, strict; quartiles
    pert_Rs = [R_by_key[k] for k in pert_keys]
    G3_flares = sum(1 for r in pert_Rs if r > TOL)
    pertR_sorted = sorted(pert_Rs)
    N = len(pertR_sorted)
    quartiles = [pertR_sorted[int(p * (N - 1))] for p in (0.25, 0.5, 0.75)]

    # reference: max R over the 20 cal trials
    cal_Rs = [R_by_key[k] for k in cal_keys]
    cal_maxR = max(cal_Rs)

    print(f"G0_R          = %.3e" % G0)
    print(f"G1_worst      = %.3e" % G1_worst)
    print(f"G1_within     = {G1_within} / {len(court_keys)}")
    print(f"G2_flares     = {G2_flares} / {len(fake_keys)}")
    print(f"G3_flares     = {G3_flares} / {len(pert_keys)}")
    print(
        "G3_quartiles  = %.3e / %.3e / %.3e"
        % (quartiles[0], quartiles[1], quartiles[2])
    )
    print(f"cal_maxR      = %.3e" % cal_maxR)

    asserts_failed = []
    if not (G0 <= 2.533e-14):
        asserts_failed.append(f"G0 {G0!r} > 2.533e-14")
    if not (G1_worst <= 1.00452e-2):
        asserts_failed.append(f"G1_worst {G1_worst!r} > 1.00452e-2")
    if not (len(fake_keys) == 50):
        asserts_failed.append(f"fakes count {len(fake_keys)} != 50")
    if not (len(pert_keys) == 50):
        asserts_failed.append(f"pert count {len(pert_keys)} != 50")

    if asserts_failed:
        print("ASSERT FAILURES:")
        for msg in asserts_failed:
            print(f"  - {msg}")
        raise SystemExit("STOP: gate assertions failed, fixture not written")

    # --- write fixture ---
    FIXTURES.mkdir(parents=True, exist_ok=True)

    fixture = {
        "formula": FORMULA_LINES,
        "warmup": WARM,
        "n": 2048,
        "tolerance": TOL,
        "toleranceControl": TOL0,
        "trials": trials_out,
        "gates": {
            "G0_R": G0,
            "G1_worst": G1_worst,
            "G1_within": G1_within,
            "G2_flares": G2_flares,
            "G3_flares": G3_flares,
            "G3_quartiles": quartiles,
            "cal_maxR": cal_maxR,
        },
        "sources": {
            "w1_kernels.json": KERNELS_SHA,
            "w1_records.json": RECORDS_SHA,
        },
        "generatedBy": "dagdb/scripts/w1_residuals.py",
        "numpyVersion": np.__version__,
    }

    residuals_path = FIXTURES / "w1_residuals_v1.json"
    with open(residuals_path, "w") as f:
        json.dump(fixture, f, indent=1)
        f.write("\n")

    # copy kernels file byte-identical
    kernels_dst = FIXTURES / "w1_kernels.json"
    kernels_dst.write_bytes(KERNELS_SRC.read_bytes())

    # sha256 sidecars, shasum -a 256 format
    kernels_sha = sha256_file(kernels_dst)
    residuals_sha = sha256_file(residuals_path)

    (FIXTURES / "w1_kernels.sha256").write_text(
        f"{kernels_sha}  {kernels_dst.name}\n"
    )
    (FIXTURES / "w1_residuals_v1.sha256").write_text(
        f"{residuals_sha}  {residuals_path.name}\n"
    )

    wall_ms = (time.time() - t_start) * 1000.0
    print(f"wall time: {wall_ms:.1f} ms")
    print(f"wrote {residuals_path} sha256={residuals_sha}")
    print(f"wrote {kernels_dst} sha256={kernels_sha}")


if __name__ == "__main__":
    run()
