# Frequency measurements

`rumble-frequency.csv` contains acoustic peak estimates from two 48 kHz recordings of one Switch 2 Pro controller. The measurements were collected on 2026-10-18; the figure is regenerated from these stored estimates, not from new hardware measurements.

Session 1 contains three left-side LF tones (codes 225, 321 and 417, amplitude code 96). Session 2 contains twelve tone intervals: six frequency probes, four amplitude probes at code 385, one simultaneous LF/HF probe, and one right-side LF probe. The dual-band interval yields two estimates, giving sixteen carrier estimates across both sessions. Repeated frequencies and two bands from one interval are not independent devices or independent frequency settings.

The numeric values were transcribed without rounding from `ns2-frequency-fit.json` (`measured_peak_hz`) and `ns2-round2-results.json` (`carriers[].measured_hz`), produced by the original local analysis scripts. Tone IDs in session 1 follow recording order; session 2 retains the probe index. No audio, device identifiers or absolute local paths are included.

The analysis removes the segment mean, applies a Hann window and computes an eight-times zero-padded FFT. It selects the largest local peak within ±15% of the candidate frequency in session 1 or ±6% in session 2, then refines the peak by maximizing the windowed sinusoidal projection. Session 1 uses 1.4 s windows; session 2 excludes the first 0.20 s and last 0.15 s of each tone, leaving approximately 0.92–0.94 s. Peak selection is conditioned on the candidate relation, not a blind search over all frequencies. Zero padding and decimal output do not establish measurement accuracy.

The controller and microphone clocks were not calibrated against a common frequency standard. There are no repeatability-based error bars. These observations support the encoding relation over the sampled frequencies, approximately 50–640 Hz; they do not establish full-range accuracy, actuator force, or console-equivalent perceived intensity.

Reproduce the PNG, SVG and PDF from the repository root:

```sh
python3 -m pip install -r tools/requirements-figures.txt
python3 tools/plot_rumble_frequency.py
```
