#!/usr/bin/env python3
"""
Synthesises the score for the promotional film.

The cues are read from storyboard.json rather than typed in, so a scene that
moves in the edit takes its bell with it. Writes a 48 kHz stereo WAV.

    python3 music.py --out ../../.promo-build/score.wav
"""
import argparse
import json
import math
import pathlib
import struct
import wave

import numpy as np

SR = 48_000
HERE = pathlib.Path(__file__).resolve().parent


def note(name: str) -> float:
    """Scientific pitch name -> Hz. A4 = 440."""
    steps = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    letter, rest = name[0].upper(), name[1:]
    semis = steps[letter]
    while rest and rest[0] in "#b":
        semis += 1 if rest[0] == "#" else -1
        rest = rest[1:]
    return 440.0 * 2 ** (semis / 12 + (int(rest) - 4))


def env_adsr(n: int, a: float, d: float, s: float, r: float) -> np.ndarray:
    """Attack/decay/sustain/release over n samples, times in seconds."""
    a_n, d_n, r_n = (max(1, int(x * SR)) for x in (a, d, r))
    sus_n = max(0, n - a_n - d_n - r_n)
    return np.concatenate([
        np.linspace(0.0, 1.0, a_n) ** 1.6,
        np.linspace(1.0, s, d_n),
        np.full(sus_n, s),
        np.linspace(s, 0.0, r_n) ** 1.8,
    ])[:n]


def one_pole(x: np.ndarray, cutoff: float) -> np.ndarray:
    """Cheap low-pass. Takes the edge off the additive harmonics."""
    a = math.exp(-2 * math.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(x.size):                       # vectorising this needs an IIR
        acc = (1 - a) * x[i] + a * acc            # solver; 3 M samples is fast enough
        y[i] = acc
    return y


def pad(buf: np.ndarray, freq: float, t0: float, dur: float, gain: float) -> None:
    """A slow, detuned pad voice — the bed the whole film sits on."""
    n = int(dur * SR)
    i0 = int(t0 * SR)
    if i0 >= buf.size:
        return
    n = min(n, buf.size - i0)
    t = np.arange(n) / SR
    voice = np.zeros(n)
    # a handful of harmonics, each detuned a touch so the pad never sounds like
    # a test tone
    for k, amp, cents in ((1, 1.00, 0.0), (1, 0.55, +6.0), (1, 0.55, -7.0),
                          (2, 0.24, +3.0), (3, 0.11, -4.0), (4, 0.05, +2.0)):
        f = freq * k * 2 ** (cents / 1200)
        voice += amp * np.sin(2 * math.pi * f * t + (k * 1.7 + cents))
    voice /= 2.5
    # slow amplitude drift, so a held chord still moves
    voice *= 1.0 + 0.10 * np.sin(2 * math.pi * 0.07 * t + freq % 3)
    voice *= env_adsr(n, a=1.6, d=1.0, s=0.80, r=2.2)
    buf[i0:i0 + n] += gain * voice


def bell(buf: np.ndarray, freq: float, t0: float, gain: float, decay: float = 2.6) -> None:
    """A soft struck tone. One per scene change."""
    n = int(min(decay * 3, 7.0) * SR)
    i0 = int(t0 * SR)
    if i0 >= buf.size:
        return
    n = min(n, buf.size - i0)
    t = np.arange(n) / SR
    voice = np.zeros(n)
    for k, amp, dk in ((1, 1.00, 1.00), (2, 0.42, 1.55), (3, 0.20, 2.10),
                       (4.2, 0.09, 2.90), (5.4, 0.05, 3.60)):
        voice += amp * np.sin(2 * math.pi * freq * k * t) * np.exp(-t * dk / decay)
    voice /= 1.8
    voice *= 1 - np.exp(-t * 900)                 # soften the transient
    buf[i0:i0 + n] += gain * voice


def sub(buf: np.ndarray, freq: float, t0: float, dur: float, gain: float) -> None:
    """Low sine underneath. Felt more than heard."""
    n = int(dur * SR)
    i0 = int(t0 * SR)
    if i0 >= buf.size:
        return
    n = min(n, buf.size - i0)
    t = np.arange(n) / SR
    voice = np.sin(2 * math.pi * freq * t) + 0.18 * np.sin(2 * math.pi * freq * 2 * t)
    voice *= env_adsr(n, a=2.0, d=1.0, s=0.85, r=2.4)
    buf[i0:i0 + n] += gain * voice


def reverb(x: np.ndarray, seconds: float = 1.9, mix: float = 0.34, seed: int = 7) -> np.ndarray:
    """Exponentially decaying noise as an impulse response, applied by FFT."""
    rng = np.random.default_rng(seed)
    n_ir = int(seconds * SR)
    t = np.arange(n_ir) / SR
    ir = rng.standard_normal(n_ir) * np.exp(-t * 4.0)
    ir[: int(0.012 * SR)] = 0.0                   # a little pre-delay
    ir /= np.abs(ir).sum() / 12
    n = 1 << int(np.ceil(np.log2(x.size + n_ir)))
    wet = np.fft.irfft(np.fft.rfft(x, n) * np.fft.rfft(ir, n), n)[: x.size]
    return (1 - mix) * x + mix * wet


# The progression. Eight bars of it, looping under the whole film.
CHORDS = [
    ("Dm9",      ["D3", "F3", "A3", "C4", "E4"], "D2"),
    ("B♭maj7", ["Bb2", "D3", "F3", "A3"],   "Bb1"),
    ("Fmaj9",    ["F2", "A2", "C3", "E3", "G3"], "F1"),
    ("Csus2",    ["C3", "G3", "D4", "E4"],       "C2"),
    ("Dm9",      ["D3", "F3", "A3", "C4", "E4"], "D2"),
    ("B♭maj7", ["Bb2", "D3", "F3", "A3"],   "Bb1"),
    ("Fmaj9",    ["F2", "A2", "C3", "E3", "G3"], "F1"),
    ("Dm(add9)", ["D3", "A3", "C4", "E4"],       "D2"),
]


def build(total: float, cues: list[float]) -> np.ndarray:
    n = int(total * SR)
    buf = np.zeros(n + SR)                        # tail room for the last release

    bar = total / len(CHORDS)
    for i, (_, voices, root) in enumerate(CHORDS):
        t0 = i * bar
        # the middle of the film carries more weight than the open and the close
        arc = 0.62 + 0.38 * math.sin(math.pi * (i + 0.5) / len(CHORDS))
        for j, nm in enumerate(voices):
            pad(buf, note(nm), t0, bar + 2.6, gain=0.100 * arc * (1.0 - 0.07 * j))
        sub(buf, note(root), t0, bar + 2.0, gain=0.085 * arc)

    # one bell per scene change, climbing the chord it lands in
    ladder = ["D4", "A4", "F4", "C5", "E5", "A4", "D5", "F5", "A5"]
    for i, t0 in enumerate(cues):
        if t0 <= 0.01:
            continue                              # the film opens on silence
        g = 0.055 + 0.030 * (i / max(1, len(cues) - 1))
        bell(buf, note(ladder[i % len(ladder)]), t0 - 0.10, gain=g, decay=2.8)

    buf = one_pole(buf, cutoff=3200.0)
    buf = reverb(buf)
    buf = buf[:n]

    # ease in from nothing, resolve to nothing
    t = np.arange(n) / SR
    buf *= np.clip(t / 2.2, 0, 1) ** 1.4
    buf *= np.clip((total - t) / 4.0, 0, 1) ** 1.3

    peak = np.abs(buf).max()
    if peak > 0:
        buf *= 10 ** (-3.0 / 20) / peak           # leave 3 dB of headroom

    # a narrow stereo spread; the same signal twice reads as mono and flat
    delay = int(0.011 * SR)
    left = buf.copy()
    right = np.concatenate([np.zeros(delay), buf[:-delay]]) * 0.97
    return np.stack([left, right], axis=1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="../../.promo-build/score.wav")
    args = ap.parse_args()

    sb = json.loads((HERE / "storyboard.json").read_text())
    total = float(sb["duration_seconds"])
    cues = [float(s["start"]) for s in sb["scenes"]]

    stereo = build(total, cues)
    out = (HERE / args.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)

    pcm = np.clip(stereo, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2")
    with wave.open(str(out), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"wrote {out}  {total:.2f}s  {len(cues)} cues")


if __name__ == "__main__":
    main()
