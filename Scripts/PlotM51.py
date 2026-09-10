"""Plot actual M51 ScenarioSmoke snapshots. Requires numpy and matplotlib.
Usage: python Scripts/PlotM51.py /tmp/galaxy-m51-snapshots docs/images/m51-evolution.png
"""
import sys
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

root, destination = map(Path, sys.argv[1:3])
length = 2.26
velocity = (4.30091e-6 * 1e10 / length) ** 0.5
time_myr = 977.7922 * length / velocity
fig, axes = plt.subplots(2, 3, figsize=(14, 9), facecolor="#060b15")
for ax, step in zip(axes.flat, [0, 300, 600, 900, 1200, 1500]):
    data = np.fromfile(root / f"m51-{step}.bin", dtype=np.float32).reshape(-1, 8)
    ax.set_facecolor("#060b15")
    for population, color in [(0, "#79d9ff"), (1, "#ffb761")]:
        stars = data[data[:, 7] == population]
        ax.scatter(stars[:, 0] * length, stars[:, 1] * length, s=0.7,
                   alpha=0.45, c=color, rasterized=True)
    ax.set(xlim=(-25, 25), ylim=(-25, 25), aspect="equal")
    ax.set_title(f"Elapsed {step / 60 * time_myr:.0f} Myr", color="white", fontsize=13)
    ax.set_xlabel("Sky x (kpc)", color="#a4b3c8")
    ax.set_ylabel("Sky y (kpc)", color="#a4b3c8")
    ax.tick_params(colors="#a4b3c8", labelsize=8)
fig.suptitle("M51 approximation — live stellar dynamics, no gas or dust", color="white", fontsize=17)
fig.tight_layout(pad=2)
destination.parent.mkdir(parents=True, exist_ok=True)
fig.savefig(destination, dpi=130, facecolor=fig.get_facecolor())
