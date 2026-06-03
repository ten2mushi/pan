#!/usr/bin/env python3
"""Cross-validate pan's rfftForward against scipy.fft.rfft (on-demand, NOT hermetic).
Reads pan's bins from stdin ('re im' per line) and compares to scipy on the same
deterministic analytic signal. Exits 0 iff allclose."""
import sys, numpy as np
from scipy.fft import rfft
N = 1024
n = np.arange(N)
x = np.sin(2*np.pi*3*n/N) + 0.5*np.sin(2*np.pi*7*n/N)
ref = rfft(x)  # length N/2+1 complex
pan = []
for line in sys.stdin:
    re, im = line.split()
    pan.append(float(re) + 1j*float(im))
pan = np.array(pan)
ok = np.allclose(pan, ref, atol=1e-2, rtol=1e-3)
maxerr = np.max(np.abs(pan - ref))
print(f"pan rfft vs scipy.fft.rfft: allclose={ok}  max_abs_err={maxerr:.6g}  bins={len(pan)}")
sys.exit(0 if ok else 1)
