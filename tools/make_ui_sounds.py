#!/usr/bin/env python3
"""Generates the game's UI sounds as 16-bit mono WAVs into sounds/ui/.

These are synthesised rather than recorded on purpose. Menu blips are the one
category where a synthetic character is the RIGHT character -- a recorded click
sounds like someone's desk, a generated one sounds like a machine responding.
They are also the category you want dead consistent across a hundred presses a
session, which recording does not give you for free.

The palette is a heavy ship console: low, chunky, and pitched without being
musical. That last part is the whole design. A sine wave IS a note, so anything
built out of sines sounds like a test tone no matter how it is enveloped --
which is why the bodies here are resonance rather than oscillation. A short
burst of noise is fired into a high-Q bandpass filter and the filter rings; the
ring has a pitch, but it decays the way a struck object decays instead of
holding like an instrument. Weight comes from a separate low thump underneath,
kept around 100-160 Hz so it survives laptop speakers rather than disappearing
into sub-bass nobody can reproduce.

The layer levels are not guesses. They were solved against a measured target
balance -- roughly 18% of the energy below 120 Hz, half in the 120-300 Hz body,
and the rest spread above it -- because the two failure modes here are easy to
fall into by ear and easy to catch with a spectrum: all low end reads as a boom
and vanishes on laptop speakers, all high end reads as thin. A low sine is far
more energy-dense than a decaying resonance, so it has to sit much lower in the
mix than it looks like it should.

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


def _env(i, n, attack, decay):
    """Fast-attack, exponential-decay envelope.

    The attack ramp is not optional: a waveform that starts at full amplitude
    on sample zero produces a DC step, which is audible as a nasty tick in
    front of the sound you actually wanted. The tail ramp is the same problem
    at the other end.
    """
    t = i / RATE
    a = min(1.0, t / attack) if attack > 0 else 1.0
    tail = min(1.0, (n - i) / (0.005 * RATE))
    return a * tail * math.exp(-decay * t)


def _burst(n, ms, rng):
    """The excitation: a very short noise blip that dies almost immediately.

    Nothing here is audible on its own. It exists to whack the filter below,
    the same way the sound of a hammer is not the sound of the bell.
    """
    out = [0.0] * n
    k = int(ms * 0.001 * RATE)
    prev = 0.0
    for i in range(min(k, n)):
        w = rng.uniform(-1.0, 1.0)
        prev = prev * 0.4 + w * 0.6
        out[i] = prev * math.exp(-9.0 * i / max(k, 1))
    out[0] += 0.8  # a click of impulse, so the filter starts with real energy
    return out


def thock(buf, freq, dur, amp, q=8.0, decay=20.0, exc_ms=3.0, bend=1.0,
          start=0.0, seed=1):
    """A resonant knock: noise fired into a ringing bandpass.

    `q` is what decides whether this reads as a hit or as a note. Low (2-4) is
    a dull thud with barely any pitch; high (12+) starts ringing long enough to
    sound tonal again, which is the thing being avoided. 6-10 is the useful
    band -- clearly pitched, clearly struck.

    A state-variable filter, taking the bandpass output. `bend` slides the
    resonant frequency across the sound; falling slightly is what a real struck
    object does as it loses energy, and it costs nothing to imitate.
    """
    n = int(dur * RATE)
    off = int(start * RATE)
    exc = _burst(n, exc_ms, random.Random(seed))
    low = 0.0
    band = 0.0
    damp = 1.0 / q
    peak = 1e-9
    tmp = [0.0] * n
    for i in range(n):
        fc = freq * (bend ** (i / max(n - 1, 1)))
        f = 2.0 * math.sin(math.pi * min(fc, RATE * 0.45) / RATE)
        high = exc[i] - low - damp * band
        band += f * high
        low += f * band
        v = band * _env(i, n, 0.0004, decay)
        tmp[i] = v
        peak = max(peak, abs(v))
    # Normalised per-voice so `amp` means the same thing at every frequency:
    # a bandpass passes wildly different energy at 90 Hz and at 900 Hz, and
    # without this every recipe would need its levels retuned by ear.
    k = amp / peak
    for i in range(n):
        j = off + i
        if j < len(buf):
            buf[j] += tmp[i] * k


def thump(buf, freq, dur, amp, decay=26.0, bend=0.75, start=0.0):
    """The low end. Short, pitched down as it goes, and gone.

    This is the only sine left in the file, and it gets away with it by being
    too brief to register as a note -- 60 ms of 120 Hz is a thud, not a tone.
    It is what the sounds were missing: pitch without weight sounds thin
    however loud you make it.
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
        buf[j] += amp * _env(i, n, 0.001, decay) * math.sin(phase)


def ring(buf, freqs, dur, amp, decay=30.0, start=0.0):
    """A faint inharmonic shimmer over the top: the metal in the console.

    The ratios are deliberately not whole numbers. Harmonically related
    partials fuse into one pitch and sound like an instrument; unrelated ones
    stay heard as material.
    """
    n = int(dur * RATE)
    off = int(start * RATE)
    for f in freqs:
        phase = 0.0
        for i in range(n):
            j = off + i
            if j >= len(buf):
                break
            phase += 2.0 * math.pi * f / RATE
            buf[j] += (amp / len(freqs)) * _env(i, n, 0.0006, decay) \
                * math.sin(phase)


def tap(buf, dur, amp, decay=260.0, start=0.0, seed=3):
    """A tiny high-frequency transient: the fingertip on the key.

    Weight without one of these reads as a boom rather than as a press, and it
    is the only part of the sound a laptop speaker reproduces properly. Made by
    differencing noise, which is a one-line highpass.
    """
    n = int(dur * RATE)
    off = int(start * RATE)
    rng = random.Random(seed)
    prev = 0.0
    for i in range(n):
        j = off + i
        if j >= len(buf):
            break
        w = rng.uniform(-1.0, 1.0)
        buf[j] += amp * _env(i, n, 0.0002, decay) * (w - prev) * 0.5
        prev = w


def sweep(buf, f0, f1, dur, amp, q=3.5, decay=5.0, start=0.0, seed=5):
    """Noise driven through a filter whose cutoff travels.

    For the menu itself rather than for a button: opening and closing are the
    two biggest events in the UI and they get the only sounds with any
    movement in them. Rising reads as opening, falling as closing, and neither
    needs a melody to say so.
    """
    n = int(dur * RATE)
    off = int(start * RATE)
    rng = random.Random(seed)
    low = 0.0
    band = 0.0
    damp = 1.0 / q
    prev = 0.0
    tmp = [0.0] * n
    peak = 1e-9
    for i in range(n):
        w = rng.uniform(-1.0, 1.0)
        prev = prev * 0.5 + w * 0.5
        fc = f0 * ((f1 / f0) ** (i / max(n - 1, 1)))
        f = 2.0 * math.sin(math.pi * min(fc, RATE * 0.45) / RATE)
        high = prev - low - damp * band
        band += f * high
        low += f * band
        v = band * _env(i, n, 0.012, decay)
        tmp[i] = v
        peak = max(peak, abs(v))
    k = amp / peak
    for i in range(n):
        j = off + i
        if j < len(buf):
            buf[j] += tmp[i] * k


def write(name, buf, peak=0.72):
    """Normalises to a fixed peak and writes the WAV.

    Normalising matters more than it looks: these get played back to back with
    each other, and one blip 6 dB hotter than its neighbours is the thing that
    makes a menu feel cheap. Levelling here rather than in the game also means
    the volume trims in audio.gd stay meaningful when a recipe changes.
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
    # button, so anything with presence becomes torture inside a minute. Low Q
    # and no thump: this should read as a texture, not as an event.
    for k, f in enumerate((430.0, 468.0, 402.0)):
        b = blank(0.045)
        thock(b, f, 0.04, 1.0, q=3.0, decay=95.0, exc_ms=1.6, seed=40 + k)
        write("hover_%d" % (k + 1), b, peak=0.15)

    # --- click ---------------------------------------------------------------
    # The main press, and the sound everything else is judged against. Three
    # layers: the low thump for weight, the resonant body for pitch, and a
    # barely-there metallic ring so it sounds like a console and not a box.
    for k, f in enumerate((236.0, 244.0, 229.0)):
        b = blank(0.16)
        thump(b, 118.0, 0.055, 0.55, decay=58.0, bend=0.7)
        thock(b, f, 0.14, 1.0, q=7.5, decay=30.0, exc_ms=3.2, bend=0.88,
              seed=10 + k)
        # The upper voice and the transient keep the SAME seed across the
        # three takes. Only the body moves. Varying every layer at once made
        # three different sounds rather than one object struck three times --
        # measurably so: the body band swung from 19% to 46% of the energy.
        thock(b, f * 3.1, 0.14, 1.5, q=4.0, decay=24.0, exc_ms=1.4, seed=90)
        tap(b, 0.04, 0.30, decay=90.0, seed=3)
        ring(b, [f * 8.7, f * 13.3], 0.06, 0.06, decay=55.0)
        write("click_%d" % (k + 1), b, peak=0.70)

    # --- back ----------------------------------------------------------------
    # The same object hit lower and softer, with the metal taken off it.
    # Leaving a page should not sound identical to entering one.
    b = blank(0.19)
    thump(b, 92.0, 0.07, 0.55, decay=46.0, bend=0.68)
    thock(b, 168.0, 0.17, 1.0, q=6.5, decay=25.0, exc_ms=4.0, bend=0.84,
          seed=20)
    thock(b, 521.0, 0.16, 1.9, q=3.5, decay=26.0, exc_ms=1.4, seed=22)
    tap(b, 0.035, 0.22, decay=95.0, seed=23)
    write("back", b, peak=0.68)

    # --- toggles -------------------------------------------------------------
    # Two knocks, up for on and down for off, so a checkbox tells you what it
    # did without you having to look at it. The thump goes on the first hit
    # only -- weight on both would make a switch sound like two presses.
    b = blank(0.2)
    thump(b, 104.0, 0.05, 0.45, decay=60.0)
    thock(b, 196.0, 0.09, 0.9, q=6.0, decay=40.0, seed=51)
    thock(b, 608.0, 0.09, 1.5, q=3.5, decay=38.0, exc_ms=1.4, seed=59)
    thock(b, 310.0, 0.13, 1.0, q=7.0, decay=30.0, start=0.058, seed=52)
    thock(b, 961.0, 0.12, 1.5, q=3.5, decay=30.0, exc_ms=1.4, start=0.058,
          seed=60)
    tap(b, 0.025, 0.20, decay=100.0, seed=55)
    tap(b, 0.025, 0.20, decay=100.0, start=0.058, seed=56)
    write("toggle_on", b, peak=0.6)

    b = blank(0.2)
    thump(b, 104.0, 0.05, 0.45, decay=60.0)
    thock(b, 310.0, 0.09, 0.9, q=7.0, decay=40.0, seed=53)
    thock(b, 961.0, 0.09, 1.5, q=3.5, decay=38.0, exc_ms=1.4, seed=67)
    thock(b, 196.0, 0.13, 1.0, q=6.0, decay=30.0, start=0.058, seed=54)
    thock(b, 608.0, 0.12, 1.5, q=3.5, decay=30.0, exc_ms=1.4, start=0.058,
          seed=68)
    tap(b, 0.025, 0.20, decay=100.0, seed=57)
    tap(b, 0.025, 0.20, decay=100.0, start=0.058, seed=58)
    write("toggle_off", b, peak=0.6)

    # --- slider tick ---------------------------------------------------------
    # Fires once per step of a slider, so it is barely there by design: this is
    # texture under a drag, not an event. Detent on a machined dial.
    b = blank(0.035)
    thock(b, 620.0, 0.03, 1.0, q=2.4, decay=150.0, exc_ms=1.0, seed=31)
    write("tick", b, peak=0.13)

    # --- open / close --------------------------------------------------------
    # The menu itself: bigger than a button because it is a bigger event, and
    # the only place anything moves. A filter travelling up over a low body --
    # a console coming to life rather than a chime.
    b = blank(0.40)
    thump(b, 76.0, 0.16, 0.22, decay=18.0, bend=1.25)
    sweep(b, 150.0, 900.0, 0.34, 1.0, q=3.2, decay=6.0)
    write("open", b, peak=0.52)

    b = blank(0.40)
    thump(b, 96.0, 0.17, 0.24, decay=17.0, bend=0.72)
    sweep(b, 820.0, 140.0, 0.32, 1.0, q=3.2, decay=7.0, seed=6)
    write("close", b, peak=0.52)

    # --- rebinding -----------------------------------------------------------
    # "Waiting for a key": one knock left ringing longer than anything else
    # here, so it sounds unfinished. It is -- the game is waiting on you.
    b = blank(0.26)
    thock(b, 330.0, 0.24, 0.9, q=11.0, decay=16.0, exc_ms=2.4, seed=61)
    write("prompt", b, peak=0.46)

    # "Got it": three knocks climbing. Resonances rather than notes, so it
    # lands as a mechanism completing instead of as a little tune.
    b = blank(0.28)
    thump(b, 110.0, 0.05, 0.45, decay=55.0)
    tap(b, 0.008, 0.16, seed=74)
    thock(b, 210.0, 0.09, 0.8, q=6.5, decay=42.0, seed=71)
    thock(b, 296.0, 0.09, 0.8, q=6.5, decay=42.0, start=0.055, seed=72)
    thock(b, 420.0, 0.15, 0.85, q=7.5, decay=26.0, start=0.108, seed=73)
    write("accept", b, peak=0.6)

    # --- deny ----------------------------------------------------------------
    # For anything refused. Two heavy low knocks with no pitch movement at all,
    # which is what makes it read as a wall rather than as a transition.
    b = blank(0.3)
    thump(b, 82.0, 0.09, 0.30, decay=38.0, bend=0.9)
    thock(b, 172.0, 0.12, 1.0, q=5.0, decay=34.0, exc_ms=4.5, seed=81)
    thock(b, 386.0, 0.14, 1.1, q=3.0, decay=30.0, exc_ms=2.0, seed=83)
    thump(b, 78.0, 0.10, 0.28, decay=34.0, bend=0.9, start=0.095)
    thock(b, 164.0, 0.16, 0.95, q=5.0, decay=26.0, exc_ms=4.5, start=0.095,
          seed=82)
    thock(b, 368.0, 0.16, 1.1, q=3.0, decay=28.0, exc_ms=2.0, start=0.095,
          seed=84)
    write("deny", b, peak=0.72)


if __name__ == "__main__":
    main()
