#!/usr/bin/env python3
"""Generates the game's UI sounds as 16-bit mono WAVs into sounds/ui/.

These are synthesised rather than recorded on purpose. Menu blips are the one
category where a synthetic character is the RIGHT character -- a recorded click
sounds like someone's desk, a generated one sounds like a machine responding.
They are also the category you want dead consistent across a hundred presses a
session, which recording does not give you for free.

Everything here is stdlib. Re-run it after editing a recipe:

    python tools/make_ui_sounds.py

Nothing else in the project reads this file; the WAVs it writes are the
artefacts. It is committed so the sounds can be tweaked rather than being
opaque binaries nobody can regenerate.
"""

import math
import os
import random
import struct
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "sounds", "ui")


def env(i, n, attack=0.003, decay=6.0):
    """Fast-attack, exponential-decay envelope.

    The attack ramp is not optional: a waveform that starts at full amplitude
    on sample zero produces a DC step, which is audible as a nasty tick in
    front of the sound you actually wanted.
    """
    t = i / RATE
    a = min(1.0, t / attack) if attack > 0 else 1.0
    tail = min(1.0, (n - i) / (0.004 * RATE))  # ramp the last few ms to zero
    return a * tail * math.exp(-decay * t)


def tone(buf, freq, dur, amp, decay=6.0, harm=0.0, bend=1.0, start=0.0):
    """Adds a sine (plus optional octave) with an exponential decay.

    `bend` is the ratio the pitch slides to across the sound -- >1 rises,
    <1 falls. Rising reads as "opening/accepting", falling as
    "closing/cancelling", which is most of what a UI needs to say.
    """
    n = int(dur * RATE)
    off = int(start * RATE)
    phase = 0.0
    for i in range(n):
        j = off + i
        if j >= len(buf):
            break
        f = freq * (bend ** (i / max(n - 1, 1)))
        phase += 2.0 * math.pi * f / RATE
        e = env(i, n, decay=decay)
        s = math.sin(phase)
        if harm:
            s += harm * math.sin(2.0 * phase)
        buf[j] += amp * e * s / (1.0 + harm)


def noise(buf, dur, amp, decay=40.0, start=0.0, rng=None):
    """A very short filtered-noise transient: the 'tick' of the click.

    A pure sine blip sounds like a test tone. The tiny burst of noise in front
    of it is what makes it read as something being pressed.
    """
    rng = rng or random.Random(7)
    n = int(dur * RATE)
    off = int(start * RATE)
    prev = 0.0
    for i in range(n):
        j = off + i
        if j >= len(buf):
            break
        w = rng.uniform(-1.0, 1.0)
        prev = prev * 0.55 + w * 0.45  # one-pole lowpass: takes the fizz off
        buf[j] += amp * env(i, n, attack=0.0005, decay=decay) * prev


def write(name, buf, peak=0.72):
    """Normalises to a fixed peak and writes the WAV.

    Normalising matters more than it looks: these get played back to back with
    each other, and one blip 6 dB hotter than its neighbours is the thing that
    makes a menu feel cheap.
    """
    hi = max(1e-9, max(abs(v) for v in buf))
    k = peak / hi
    frames = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v * k)) * 32767))
                      for v in buf)
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)
    print("  %-22s %5d ms" % (name + ".wav", len(buf) * 1000 // RATE))


def blank(dur):
    return [0.0] * int(dur * RATE)


def main():
    os.makedirs(OUT, exist_ok=True)
    print("writing to", OUT)

    # --- hover ---------------------------------------------------------------
    # The quietest thing in the game. It fires every time the mouse crosses a
    # button, so anything with presence would become torture inside a minute.
    for k, f in enumerate((2100.0, 2260.0, 1980.0)):
        b = blank(0.05)
        tone(b, f, 0.045, 0.5, decay=70.0, harm=0.15)
        write("hover_%d" % (k + 1), b, peak=0.16)

    # --- click ---------------------------------------------------------------
    # The main press. Noise transient, a body note, and a short octave above it
    # so it has a defined pitch instead of just being a thud.
    for k, f in enumerate((760.0, 800.0, 725.0)):
        b = blank(0.13)
        noise(b, 0.012, 0.45, decay=170.0, rng=random.Random(11 + k))
        tone(b, f, 0.11, 0.75, decay=34.0, harm=0.3, bend=0.92)
        tone(b, f * 2.98, 0.05, 0.22, decay=70.0)
        write("click_%d" % (k + 1), b, peak=0.62)

    # --- back ----------------------------------------------------------------
    # Same click, pitched down and falling. Leaving a page should not sound
    # identical to entering one.
    b = blank(0.15)
    noise(b, 0.012, 0.4, decay=170.0, rng=random.Random(21))
    tone(b, 470.0, 0.13, 0.8, decay=30.0, harm=0.25, bend=0.82)
    write("back", b, peak=0.6)

    # --- toggles -------------------------------------------------------------
    # A two-note pair, up for on and down for off, so a checkbox tells you what
    # it did without you having to look at it.
    b = blank(0.17)
    tone(b, 620.0, 0.07, 0.6, decay=42.0, harm=0.2)
    tone(b, 930.0, 0.11, 0.6, decay=30.0, harm=0.2, start=0.055)
    write("toggle_on", b, peak=0.5)

    b = blank(0.17)
    tone(b, 930.0, 0.07, 0.6, decay=42.0, harm=0.2)
    tone(b, 620.0, 0.11, 0.55, decay=30.0, harm=0.2, start=0.055)
    write("toggle_off", b, peak=0.5)

    # --- slider tick ---------------------------------------------------------
    # Fires once per step of a slider, so it is barely there by design: this is
    # texture under a drag, not an event.
    b = blank(0.03)
    noise(b, 0.008, 0.5, decay=260.0, rng=random.Random(31))
    tone(b, 1500.0, 0.025, 0.35, decay=140.0)
    write("tick", b, peak=0.13)

    # --- open / close --------------------------------------------------------
    # The menu itself. Bigger than a button press because it is a bigger event,
    # and a rising/falling pair for the same reason as the toggles.
    b = blank(0.34)
    tone(b, 330.0, 0.30, 0.55, decay=9.0, harm=0.35, bend=1.55)
    tone(b, 660.0, 0.22, 0.22, decay=13.0, bend=1.55)
    write("open", b, peak=0.42)

    b = blank(0.34)
    tone(b, 520.0, 0.30, 0.55, decay=9.0, harm=0.35, bend=0.62)
    tone(b, 1040.0, 0.20, 0.20, decay=14.0, bend=0.62)
    write("close", b, peak=0.42)

    # --- rebinding -----------------------------------------------------------
    # "Waiting for a key" and "got it". The prompt deliberately does not
    # resolve -- it sits on one note so it sounds unfinished, because it is.
    b = blank(0.16)
    tone(b, 1180.0, 0.13, 0.5, decay=26.0, harm=0.2)
    write("prompt", b, peak=0.4)

    b = blank(0.24)
    tone(b, 700.0, 0.09, 0.6, decay=40.0, harm=0.25)
    tone(b, 1050.0, 0.09, 0.6, decay=40.0, harm=0.25, start=0.06)
    tone(b, 1400.0, 0.14, 0.6, decay=26.0, harm=0.25, start=0.115)
    write("accept", b, peak=0.5)

    # --- deny ----------------------------------------------------------------
    # For anything refused. Two flat low notes: no pitch movement at all, which
    # is what makes it read as a wall rather than as a transition.
    b = blank(0.26)
    tone(b, 300.0, 0.10, 0.7, decay=34.0, harm=0.4)
    tone(b, 285.0, 0.15, 0.7, decay=26.0, harm=0.4, start=0.085)
    write("deny", b, peak=0.55)


if __name__ == "__main__":
    main()
