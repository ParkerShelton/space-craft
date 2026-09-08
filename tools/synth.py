"""Sound synthesis primitives, shared by the UI and world sound generators.

The one idea everything here is built on: struck materials are RESONANCE, not
oscillation. A sine wave is a note, so anything built out of sines sounds like a
test tone however it is enveloped. Fire a very short burst of noise into a
bandpass filter instead and the filter rings -- pitched, but decaying the way a
struck object decays. Change the Q and the mode ratios and the same three lines
give you wood, glass, stone or metal.

Stdlib only, deliberately: these run anywhere with a Python on the path and no
install step.
"""

import math
import os
import random
import struct
import wave

RATE = 44100


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


def write_wav(path, buf, peak=0.72):
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
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)
    print("  %-24s %5d ms" % (os.path.basename(path), len(buf) * 1000 // RATE))


def blank(dur):
    return [0.0] * int(dur * RATE)




def grains(buf, n, dur, amp, f_lo, f_hi, q=3.0, decay=180.0, start=0.0,
           seed=1, bunch=1.0):
    """A scatter of tiny resonant specks: debris, crackle, crunch.

    This one function is most of what makes a material sound granular rather
    than solid. Gravel rattling out of a broken block, dry leaves crackling,
    snow compressing, glass tinkling -- they are all the same thing at
    different pitches and densities, which is a scatter of very short
    resonances at slightly different frequencies and slightly different times.

    `bunch` below 1 pulls the specks toward the start, which is what real
    debris does: most of it arrives at once and the stragglers follow.
    """
    rng = random.Random(seed)
    for i in range(n):
        t = start + dur * (rng.random() ** (1.0 / max(bunch, 0.05)))
        f = f_lo * ((f_hi / f_lo) ** rng.random())
        thock(buf, f, min(0.05, dur), amp * rng.uniform(0.45, 1.0), q=q,
              decay=decay, exc_ms=1.0, start=t, seed=seed * 31 + i,
              impulse=0.5)
