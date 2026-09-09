"""Plot actual ScenarioSmoke snapshots (optional: pip install numpy matplotlib).

Run ScenarioSmoke with GALAXY_SNAPSHOTS=/tmp/galaxy-snapshots, then:
python Scripts/PlotScenarios.py /tmp/galaxy-snapshots docs/images/scenarios.png
The plotted particles are simulation outputs, not generated illustrations.
"""
import sys
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

root, destination = Path(sys.argv[1]), Path(sys.argv[2])
cases = [("stream", 1200, 20, "Tidal stream"), ("ring", 600, 8, "Collisional ring"),
         ("prograde", 1200, 20, "Prograde encounter"), ("retrograde", 1200, 20, "Retrograde encounter"),
         ("shells", 1800, 20, "Radial shell merger"), ("bar", 900, 6, "Spontaneous stellar bar")]
fig, axes = plt.subplots(3, 2, figsize=(12, 16), facecolor="#060b15")
for ax, (name, step, limit, title) in zip(axes.flat, cases):
    data = np.fromfile(root / f"{name}-{step}.bin", dtype=np.float32).reshape(-1, 8)
    ax.set_facecolor("#060b15")
    for population, color in [(0, "#79d9ff"), (1, "#ffb761")]:
        stars = data[data[:, 7] == population]
        alpha = 0.08 if name in ["stream", "shells"] and population == 0 else 0.55
        ax.scatter(stars[:, 0], stars[:, 1], s=1, alpha=alpha, c=color, rasterized=True)
    ax.set(xlim=(-limit, limit), ylim=(-limit, limit), aspect="equal")
    ax.set_title(f"{title}  /  t = {step / 60:g}", color="white", fontsize=13, pad=12)
    ax.set_xlabel("x (simulation units)", color="#a4b3c8")
    ax.set_ylabel("y (simulation units)", color="#a4b3c8")
    ax.tick_params(colors="#a4b3c8", labelsize=8)
fig.suptitle("Galaxy Lab — snapshots from live N-body integration", color="white", fontsize=17, y=0.995)
fig.tight_layout(pad=2)
destination.parent.mkdir(parents=True, exist_ok=True)
fig.savefig(destination, dpi=130, facecolor=fig.get_facecolor())
