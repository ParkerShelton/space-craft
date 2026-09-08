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

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from synth import blank, ring, tap, thock, wood, write_wav

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "sounds", "ui")


def write(name, buf, peak=0.72):
    write_wav(os.path.join(OUT, name + ".wav"), buf, peak)


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
