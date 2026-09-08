#!/usr/bin/env python3
"""Generates the game's UI sounds as 16-bit mono WAVs into sounds/ui/.

These are synthesised rather than recorded on purpose. Menu blips are the one
category where a synthetic character is the RIGHT character -- a recorded click
sounds like someone's desk, a generated one sounds like a machine responding.
They are also the category you want dead consistent across a hundred presses a
session, which recording does not give you for free.

The palette is dry struck wood -- the Minecraft register. Short, mid-high, and
pitched without being musical.

Two rules do most of the work, both learned the hard way. First, no low end:
a short percussive hit with weight underneath is a drum, not a button, and an
earlier pass at making these "chunkier" turned the whole menu into a kit. Bass
is for things with size, and a button has none. Second, no sine bodies: a sine
IS a note, so anything built from one sounds like a test tone however it is
enveloped. The bodies here are resonance instead -- a short noise burst fired
into a bank of bandpass filters, which rings at several inharmonic frequencies
at once. That disagreement between the modes is what makes the ear hear a
material rather than a pitch.

Pops are a third thing, separate from either: a pop is a sound that starts too
abruptly, and it is fixed at the attack rather than in the tone.

Levels are checked against a spectrum rather than trusted to the ear, since
whoever last edited this may not be able to hear it. For this palette almost
everything should sit between 300 Hz and 2 kHz, with very little below 120 Hz;
anything much heavier than that is the drum problem coming back.

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


def _burst(n, ms, rng, impulse=0.8):
    """The excitation: a very short noise blip that dies almost immediately.

    Nothing here is audible on its own. It exists to whack the filter below,
    the same way the sound of a hammer is not the sound of the bell.

    `impulse` is how hard it is struck on the very first sample. It is also
    exactly what makes a sound "poppy" -- a full-scale step at sample zero is
    heard as a click in front of whatever follows. Anything that should feel
    brushed rather than struck wants this at zero.
    """
    out = [0.0] * n
    k = int(ms * 0.001 * RATE)
    prev = 0.0
    for i in range(min(k, n)):
        w = rng.uniform(-1.0, 1.0)
        prev = prev * 0.4 + w * 0.6
        out[i] = prev * math.exp(-9.0 * i / max(k, 1))
    out[0] += impulse
    return out


def thock(buf, freq, dur, amp, q=8.0, decay=20.0, exc_ms=3.0, bend=1.0,
          start=0.0, seed=1, impulse=0.8, attack=0.0004):
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
    exc = _burst(n, exc_ms, random.Random(seed), impulse)
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
        v = band * _env(i, n, attack, decay)
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


def wood(buf, freq, dur, amp, q=5.5, decay=52.0, start=0.0, seed=1,
         impulse=0.8, attack=0.0004, exc_ms=2.0, modes=(1.0, 1.48, 2.11)):
    """A dry wooden tap: one strike heard through several inharmonic modes.

    A single resonance is a tuned drum -- one pitch, and the ear names it. Real
    struck wood rings at several unrelated frequencies at once, and it is that
    disagreement between them that stops the brain hearing a note and makes it
    hear a material instead. The ratios are deliberately not whole numbers for
    the same reason.

    Short by design. Almost everything that makes a UI sound like a drum kit
    rather than a button is decay time and low end, and this has little of
    either.
    """
    for i, m in enumerate(modes):
        thock(buf, freq * m, dur, amp * (0.55 ** i), q=q,
              decay=decay * (1.0 + 0.35 * i), exc_ms=exc_ms, start=start,
              seed=seed + i * 7, impulse=impulse, attack=attack)


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
    # The quietest thing in the game, and the one that was popping. Two changes:
    # the strike impulse is gone entirely, and the attack is slowed to 5 ms.
    # Both exist to stop the sound STARTING abruptly, which is all a pop is --
    # the ear hears the edge, not the tone behind it. What is left is a brushed
    # tick rather than a tap.
    # Slowing the output envelope alone did nothing measurable -- the peak
    # still landed inside the first millisecond, because the ENERGY going in
    # was a 2 ms whack. Feeding it in over 22 ms instead is what actually
    # softens the onset.
    for k, f in enumerate((770.0, 800.0, 738.0)):
        b = blank(0.085)
        # One seed for all three takes: with the onset this soft, a different
        # noise seed changed how soft it was (0.9 ms of rise against 4.2 ms
        # between takes), and inconsistent softness is heard as the odd one
        # popping. Only the pitch varies.
        wood(b, f, 0.075, 1.0, q=3.0, decay=46.0, seed=40,
             impulse=0.0, attack=0.012, exc_ms=30.0)
        write("hover_%d" % (k + 1), b, peak=0.13)

    # --- click ---------------------------------------------------------------
    # The main press: a dry wooden tok, and nothing else. No low thump at all.
    # Pitched to sit with the hover rather than under it -- these two are
    # heard within a fraction of a second of each other on every single
    # button, so a gap between them reads as two different objects.
    # A short percussive hit with weight under it is a drum, which is exactly
    # what the last set turned into -- the fix is not less bass, it is none.
    for k, f in enumerate((800.0, 829.0, 775.0)):
        b = blank(0.085)
        # One seed across the three takes, as with the hover: varying the
        # noise as well as the pitch made take 2 land 70% of its energy in
        # the top band against take 1's 35%, which is three buttons rather
        # than one button pressed three times.
        wood(b, f, 0.08, 1.0, q=5.5, decay=58.0, seed=10)
        tap(b, 0.010, 0.16, decay=200.0, seed=3)
        write("click_%d" % (k + 1), b, peak=0.66)

    # --- back ----------------------------------------------------------------
    # A fifth below the click, which is enough to hear as a drop without
    # leaving the family. The same piece of wood, struck lower. Leaving a page should not sound
    # identical to entering one, and a pitch drop says that without needing a
    # different sound.
    b = blank(0.095)
    wood(b, 562.0, 0.09, 1.0, q=5.5, decay=52.0, seed=20)
    tap(b, 0.010, 0.13, decay=200.0, seed=23)
    write("back", b, peak=0.66)

    # --- toggles -------------------------------------------------------------
    # Two taps, up for on and down for off, so a checkbox tells you what it did
    # without you having to look at it.
    b = blank(0.14)
    wood(b, 520.0, 0.06, 0.85, q=5.0, decay=75.0, seed=51)
    wood(b, 745.0, 0.07, 0.9, q=5.5, decay=68.0, start=0.052, seed=52)
    write("toggle_on", b, peak=0.6)

    b = blank(0.14)
    wood(b, 745.0, 0.06, 0.85, q=5.5, decay=75.0, seed=53)
    wood(b, 520.0, 0.07, 0.9, q=5.0, decay=68.0, start=0.052, seed=54)
    write("toggle_off", b, peak=0.6)

    # --- slider tick ---------------------------------------------------------
    # Fires once per step of a slider, so it is barely there by design: this is
    # texture under a drag, not an event.
    b = blank(0.03)
    wood(b, 1180.0, 0.026, 1.0, q=2.6, decay=200.0, seed=31, impulse=0.35)
    write("tick", b, peak=0.12)

    # --- open / close --------------------------------------------------------
    # Deliberately NOT the swelling filter sweep these used to be. A sweep over
    # a low body is a cinematic whoosh, and next to a wooden click it sounded
    # like it came out of a different game. Two quick taps instead, climbing to
    # open and falling to close -- the same material, just more of it, because
    # opening a menu is a bigger event than pressing a button in it.
    b = blank(0.17)
    wood(b, 520.0, 0.07, 0.8, q=5.0, decay=70.0, seed=80)
    wood(b, 780.0, 0.09, 0.95, q=5.5, decay=58.0, start=0.045, seed=81)
    write("open", b, peak=0.55)

    b = blank(0.17)
    wood(b, 780.0, 0.07, 0.85, q=5.5, decay=70.0, seed=82)
    wood(b, 520.0, 0.09, 0.9, q=5.0, decay=58.0, start=0.045, seed=83)
    write("close", b, peak=0.55)

    # --- rebinding -----------------------------------------------------------
    # "Waiting for a key": struck high and left ringing longer than anything
    # else here, so it sounds unfinished. It is -- the game is waiting on you.
    b = blank(0.2)
    wood(b, 940.0, 0.19, 1.0, q=9.0, decay=26.0, seed=61)
    write("prompt", b, peak=0.42)

    # "Got it": three taps climbing. Still wood, so it lands as a mechanism
    # finishing rather than as a little tune.
    b = blank(0.22)
    wood(b, 560.0, 0.06, 0.8, q=5.5, decay=80.0, seed=71)
    wood(b, 745.0, 0.06, 0.85, q=5.5, decay=80.0, start=0.05, seed=72)
    wood(b, 1000.0, 0.09, 0.95, q=6.0, decay=58.0, start=0.098, seed=73)
    write("accept", b, peak=0.58)

    # --- deny ----------------------------------------------------------------
    # For anything refused. Two dull knocks with no pitch movement and the top
    # end taken off -- dead, not deep. The distinction matters: a low BOOM is a
    # drum again, whereas a damped thud reads as a door that will not open.
    b = blank(0.26)
    wood(b, 258.0, 0.11, 0.95, q=3.4, decay=44.0, seed=81,
         modes=(1.0, 1.42))
    wood(b, 246.0, 0.13, 0.9, q=3.4, decay=38.0, start=0.1, seed=84,
         modes=(1.0, 1.42))
    write("deny", b, peak=0.62)


if __name__ == "__main__":
    main()
