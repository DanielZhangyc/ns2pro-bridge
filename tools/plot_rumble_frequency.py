"""从声学测量摘要生成频率图；不连接硬件。
Plot the frequency mapping from acoustic measurements without accessing hardware.
"""

import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, ScalarFormatter
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "docs/data/rumble-frequency.csv"
OUTPUT = ROOT / "docs/figures"


def main():
    with DATA.open(newline="", encoding="utf-8") as source:
        records = list(csv.DictReader(source))
    codes = np.array([int(row["frequency_code"]) for row in records])
    measured = np.array([float(row["measured_hz"]) for row in records])
    predicted = 10 * np.exp2((codes - 1) / 96)
    residual = 100 * (measured / predicted - 1)
    if not len(records) or not np.all(np.isfinite(measured)) or np.any(measured <= 0):
        raise ValueError("Expected finite, positive acoustic frequency measurements")

    plt.rcParams.update({
        "font.family": "serif", "font.serif": ["STIXGeneral"],
        "mathtext.fontset": "stix", "font.size": 9,
        "axes.labelsize": 10, "axes.titlesize": 10,
        "axes.linewidth": 0.65, "lines.linewidth": 1.4,
        "xtick.direction": "out", "ytick.direction": "out",
        "xtick.major.width": 0.65, "ytick.major.width": 0.65,
        "legend.fontsize": 8, "legend.frameon": False,
        "pdf.fonttype": 42, "ps.fonttype": 42,
        "svg.hashsalt": "ns2pro-frequency-v1",
        "savefig.facecolor": "white",
    })
    fig, (mapping, error) = plt.subplots(1, 2, figsize=(7.2, 3.25))
    fig.subplots_adjust(left=0.085, right=0.985, bottom=0.20, top=0.88, wspace=0.33)
    for ax, letter, title in [(mapping, "a", "Frequency encoding"), (error, "b", "Acoustic residuals")]:
        ax.spines[["top", "right"]].set_visible(False)
        ax.grid(axis="y", color="#e3e5e7", linewidth=0.5)
        ax.set_axisbelow(True)
        ax.set_title(title, loc="left", pad=10)
        ax.text(-0.18, 1.04, letter, transform=ax.transAxes, fontweight="bold", fontsize=12)
        ax.set_xlabel("Frequency code, q")
        ax.set_xlim(190, 675)
        ax.set_xticks([193, 289, 385, 481, 577, 670])

    curve_codes = np.arange(193, 671)
    mapping.plot(curve_codes, 10 * np.exp2((curve_codes - 1) / 96), color="#25394a", label="Encoding relation")
    mapping.set_yscale("log", base=2)
    mapping.set_ylim(35, 1400)
    mapping.yaxis.set_major_locator(FixedLocator([40, 80, 160, 320, 640, 1280]))
    mapping.yaxis.set_major_formatter(ScalarFormatter())
    mapping.set_ylabel("Frequency (Hz)")
    mapping.text(0.04, 0.91, r"$f(q)=10\,2^{(q-1)/96}$", transform=mapping.transAxes, fontsize=11)
    groups = [
        ("1", "LF", "Session 1 · LF", "o", "#256c96"),
        ("2", "LF", "Session 2 · LF", "s", "#198577"),
        ("2", "HF", "Session 2 · HF", "^", "#bc6536"),
    ]
    for session, band, label, marker, color in groups:
        selected = np.array([row["session"] == session and row["band"] == band for row in records])
        for ax, values in [(mapping, measured), (error, residual)]:
            ax.scatter(codes[selected], values[selected], s=26, marker=marker,
                       facecolor="white", edgecolor=color, linewidth=1.05, zorder=3, label=label)
    mapping.legend(loc="lower right", handlelength=1.5, labelspacing=0.3)
    error.axhline(0, color="#25394a", linewidth=0.8)
    error.set_ylabel(r"$(f_{\mathrm{measured}}/f(q)-1)\times100$ (%)")
    error.set_ylim(-0.15, 0.15)
    error.set_yticks([-0.10, -0.05, 0, 0.05, 0.10])
    error.text(0.36, 0.06, "1 controller · 16 estimates\nRepeated codes may overlap", transform=error.transAxes, fontsize=8, color="#505860")
    fig.text(0.085, 0.025, "Points: acoustic peak estimates. Line: implemented encoding relation, not a statistical fit.", fontsize=8, color="#505860")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for suffix in ("png", "svg", "pdf"):
        metadata = {"Creator": "NS2 Pro Bridge"}
        if suffix == "pdf":
            metadata.update({"CreationDate": None, "ModDate": None})
        if suffix == "svg":
            metadata["Date"] = None
        path = OUTPUT / f"rumble-frequency.{suffix}"
        fig.savefig(path, dpi=300, metadata=metadata)
        print(path.relative_to(ROOT))
    plt.close(fig)
    print(f"{len(records)} carrier estimates; residual range {residual.min():+.6f}% to {residual.max():+.6f}%")


if __name__ == "__main__":
    main()
