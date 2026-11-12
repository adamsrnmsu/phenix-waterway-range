import sys, matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
src, out = sys.argv[1:3]; L = open(src).read().rstrip("\n").split("\n"); w = max(len(l) for l in L)
fig = plt.figure(figsize=(max(6, w*0.085), 0.152*len(L)+0.35), facecolor="#0f1419")
fig.text(0.01, 0.99, "\n".join(L), family="monospace", fontsize=8.5, color="#d7dde4", va="top", ha="left", linespacing=1.35)
fig.savefig(out, dpi=170, facecolor="#0f1419"); 
