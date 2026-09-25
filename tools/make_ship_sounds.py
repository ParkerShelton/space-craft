#!/usr/bin/env python3
"""Generates the ship's own sounds as 16-bit mono WAVs into sounds/ship/.

These are the wreck coming back to life, one system at a time, and then
leaving: power coming on, the scrubbers starting to breathe, an engine being
test-fired, the engines winding up for liftoff, and the chime the computer
makes when there is nothing left to fix.

Synthesised for the same reason the menu is: they are MACHINES responding, and
a machine is the one thing a synthetic voice is right for. The world sounds --
rock, wood, footsteps -- were tried this way and thrown out; a ship's power bus
is not a rock.

Two kinds of sound here that the UI set never needed. SUSTAINED ones -- a hum,
a hiss, a roar -- which are built from filtered noise and a few partials with
a slow envelope rather than from one struck resonance. And one tonal one, the
chime, which is allowed to be a note because it is a machine TELLING you
something, and a message is the one place a pitch is the point.

Everything here is stdlib. Re-run it after editing a recipe:

    python tools/make_ship_sounds.py

Drop a recorded WAV over any of these with the same name and it plays instead;
nothing in the game refers to this file.
"""

import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from synth import RATE, blank, grains, ring, tap, thock, thump, write_wav

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "sounds", "ship")


def _shape(i, n, attack, release):
    """A plain attack / hold / release envelope, in seconds, with the ends
    ramped so neither a start nor a stop is heard as a click."""
    t = i / RATE
    left = (n - i) / RATE
    a = min(1.0, t / attack) if attack > 0 else 1.0
    r = min(1.0, left / release) if release > 0 else 1.0
    # Eased, so a swell reads as a swell rather than as a ramp.
    return (a * a * (3.0 - 2.0 * a)) * (r * r * (3.0 - 2.0 * r))


def drone(buf, f0, f1, dur, amp, attack=0.3, release=0.3, start=0.0,
          partials=((1.0, 1.0), (2.0, 0.45), (3.02, 0.22), (4.1, 0.1)), seed=7):
    """A machine's hum: a few partials gliding together from f0 to f1, with a
    little slow unsteadiness in the level so it sounds driven rather than
    generated. The third and fourth partials are slightly off whole ratios,
    which is what stops it fusing into an organ note."""
    n = int(dur * RATE)
    off = int(start * RATE)
    rng = random.Random(seed)
    phases = [rng.random() * math.tau for _ in partials]
    wob = 0.0
    total = sum(w for _, w in partials)
    for i in range(n):
        j = off + i
        if j >= len(buf):
            break
        f = f0 * ((f1 / f0) ** (i / max(n - 1, 1)))
        wob = wob * 0.9995 + rng.uniform(-1.0, 1.0) * 0.0005
        v = 0.0
        for k, (ratio, w) in enumerate(partials):
            phases[k] += math.tau * f * ratio / RATE
            v += w * math.sin(phases[k])
        buf[j] += amp * (1.0 + wob * 40.0) * _shape(i, n, attack, release) * v / total


def hiss(buf, f0, f1, dur, amp, q=1.0, attack=0.1, release=0.4, start=0.0,
         seed=5):
    """Noise through a bandpass whose centre travels from f0 to f1 -- air
    through a vent, a burner's roar, an engine's rush, depending on where the
    band sits and how wide it is (`q`: under 1 is broad and rushing, over 3
    starts to whistle). Normalised so `amp` means the same at any frequency."""
    n = int(dur * RATE)
    off = int(start * RATE)
    rng = random.Random(seed)
    low = band = 0.0
    damp = 1.0 / q
    tmp = [0.0] * n
    peak = 1e-9
    for i in range(n):
        w = rng.uniform(-1.0, 1.0)
        fc = f0 * ((f1 / f0) ** (i / max(n - 1, 1)))
        f = 2.0 * math.sin(math.pi * min(fc, RATE * 0.45) / RATE)
        high = w - low - damp * band
        band += f * high
        low += f * band
        tmp[i] = band
        peak = max(peak, abs(band))
    k = amp / peak
    for i in range(n):
        j = off + i
        if j < len(buf):
            buf[j] += tmp[i] * k * _shape(i, n, attack, release)


def write(name, buf, peak=0.72):
    write_wav(os.path.join(OUT, name + ".wav"), buf, peak)


def main():
    os.makedirs(OUT, exist_ok=True)
    print("writing to", OUT)

    # --- power on ------------------------------------------------------------
    # A relay closing, then the bus coming up: a low hum that climbs as the
    # load comes on, with a thin inverter whine riding over it. The clunk has
    # to come first -- it is the "you did that" -- and the hum is the ship
    # answering.
    b = blank(2.0)
    thump(b, 70.0, 0.12, 0.9, decay=24.0)
    tap(b, 0.03, 0.5, decay=200.0)
    thock(b, 420.0, 0.08, 0.35, q=7.0, decay=40.0, start=0.015)
    drone(b, 42.0, 88.0, 1.8, 0.55, attack=0.9, release=0.5, start=0.1)
    hiss(b, 1100.0, 2600.0, 1.7, 0.07, q=7.0, attack=1.0, release=0.4, start=0.2)
    write("power_on", b)

    # --- air -----------------------------------------------------------------
    # The scrubbers starting: a valve knocks open and air comes through the
    # vents. Broad, high, settling a little lower as the pressure evens out.
    b = blank(2.8)
    thock(b, 180.0, 0.1, 0.45, q=5.0, decay=30.0)
    hiss(b, 3400.0, 2200.0, 2.7, 0.6, q=0.8, attack=0.12, release=1.3, start=0.03)
    hiss(b, 700.0, 500.0, 2.4, 0.18, q=1.2, attack=0.3, release=1.0, start=0.05, seed=9)
    write("air", b, peak=0.6)

    # --- burn ----------------------------------------------------------------
    # One engine test-fired: ignition pop, a rush that is mostly low, and a
    # crackle through it. Short -- a test, not a flight.
    b = blank(1.4)
    thump(b, 55.0, 0.2, 1.0, decay=12.0)
    hiss(b, 110.0, 70.0, 1.3, 0.9, q=0.7, attack=0.03, release=0.8)
    hiss(b, 520.0, 300.0, 1.2, 0.35, q=1.4, attack=0.02, release=0.7, seed=11)
    grains(b, 30, 0.9, 0.12, 900.0, 3200.0, q=4.0, decay=220.0, start=0.05, seed=3)
    write("burn", b)

    # --- spool ---------------------------------------------------------------
    # The engines winding up before she lifts: a whine climbing through two
    # octaves and a rush growing under it. It ends at its loudest -- the
    # liftoff burn takes over from there.
    b = blank(2.4)
    drone(b, 55.0, 230.0, 2.4, 0.5, attack=2.0, release=0.08,
          partials=((1.0, 1.0), (2.0, 0.6), (3.03, 0.35), (5.1, 0.15)))
    hiss(b, 250.0, 1800.0, 2.4, 0.35, q=1.6, attack=2.1, release=0.08, seed=13)
    hiss(b, 90.0, 140.0, 2.4, 0.4, q=0.8, attack=1.8, release=0.08, seed=17)
    write("spool", b)

    # --- nominal -------------------------------------------------------------
    # Three rising tones, bell-ish rather than beep-ish: each is two partials
    # a little apart so it rings instead of buzzing. This is the computer
    # saying "done", and the only thing in the game allowed to be a tune.
    b = blank(1.6)
    for k, f in enumerate([587.0, 740.0, 880.0]):
        ring(b, [f, f * 2.01, f * 2.76], 1.2, 0.5, decay=4.5, start=0.17 * k)
    write("nominal", b, peak=0.55)


if __name__ == "__main__":
    main()
