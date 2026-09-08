#!/usr/bin/env python3
"""Generates the block and footstep sounds as 16-bit mono WAVs into sounds/world/.

These are synthesised rather than recorded, and that is a stylistic choice
before it is a practical one. Minecraft's block sounds are not recordings of
stone either -- they are short, stylised and deliberately unreal, because
realistic foley next to blocky voxel art fights the art. A convincing recording
of breaking rock would sound wrong here in a way a hundred-millisecond
resonant thud does not.

Every material is the same three ideas in different proportions:

  a BODY   -- one or more resonances, saying how big and how hard the thing is
  GRAINS   -- a scatter of tiny specks, saying whether it is granular
  a TAP    -- a high transient, saying it was struck rather than faded in

Stone is body with a little grain. Leaves are grain with no body at all. Glass
is a high, ringing body plus very sharp grain. Metal is a body whose modes are
so far apart and so long-ringing that it stops sounding like an object being
hit and starts sounding like one being rung.

Three performances per material, and they differ in kind rather than in volume:

  break -- the loudest, the only one with a tail. Something gives way, then
           debris. Roughly twice as long as the others.
  place -- a firm set-down. Short, no debris.
  step  -- quietest and quickest. Weight transferring, not an impact.

Re-run after editing a recipe:

    python tools/make_world_sounds.py

Anything here can be replaced by a real recording later: the game addresses
these by filename (see sounds/README.md), so dropping a WAV over one is all it
takes.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from synth import blank, grains, tap, thock, wood, write_wav

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "sounds", "world")

# How many takes of each event. The game picks between them at random and
# detunes each play, so these are the raw material for the variation rather
# than the whole of it.
TAKES = {"break": 4, "place": 3, "step": 6}

# Peak each event is normalised to. Steps sit well under the rest because they
# fire several times a second and everything else fires once.
PEAK = {"break": 0.72, "place": 0.58, "step": 0.34}

# Metal and glass ring at ratios nothing else does. Wood's default modes are
# close together and die fast; a bell's are far apart and do not, which is the
# whole difference between a knock and a chime.
METAL_MODES = (1.0, 2.76, 5.40)
GLASS_MODES = (1.0, 2.34, 3.91)


# --- the materials ------------------------------------------------------------
#
# Each takes the event name and a take index, and returns a buffer. `k` should
# move the PITCH and the grain seed and leave the structure alone -- four takes
# of one block breaking, not four different blocks.

def stone(event, k):
    f = 205.0 * (1.0 + 0.035 * (k - 1))
    if event == "break":
        b = blank(0.26)
        thock(b, f, 0.15, 1.0, q=4.0, decay=38.0, exc_ms=3.5, bend=0.85,
              seed=100 + k)
        grains(b, 11, 0.20, 0.34, 300.0, 950.0, q=5.0, decay=190.0,
               start=0.02, seed=200 + k, bunch=0.55)
        tap(b, 0.02, 0.22, decay=150.0, seed=300 + k)
        return b
    if event == "place":
        b = blank(0.13)
        # Struck a little higher than the break: setting a block down is a
        # lighter event than destroying one, and pitch says so more cheaply
        # than volume does.
        thock(b, f * 1.18, 0.11, 1.0, q=4.0, decay=56.0, exc_ms=3.0,
              seed=110 + k)
        # A couple of specks and a sharper transient: the body alone put over
        # half the energy under 200 Hz, which is a thud a laptop cannot play.
        grains(b, 3, 0.06, 0.3, 420.0, 1050.0, q=4.0, decay=230.0,
               seed=510 + k, bunch=0.6)
        tap(b, 0.014, 0.30, decay=190.0, seed=310 + k)
        return b
    b = blank(0.09)
    grains(b, 5, 0.045, 0.9, 420.0, 1250.0, q=3.0, decay=240.0,
           seed=400 + k, bunch=0.5)
    thock(b, f * 1.1, 0.05, 0.35, q=2.5, decay=120.0, seed=120 + k)
    return b


def dirt(event, k):
    # The dullest thing in the set: low Q everywhere, so almost no pitch
    # survives. Dirt should sound like it absorbs the hit rather than answering
    # it.
    f = 132.0 * (1.0 + 0.04 * (k - 1))
    if event == "break":
        b = blank(0.22)
        thock(b, f, 0.14, 1.0, q=2.2, decay=44.0, exc_ms=5.0, seed=101 + k)
        grains(b, 8, 0.16, 0.26, 200.0, 620.0, q=2.0, decay=210.0,
               start=0.015, seed=201 + k, bunch=0.5)
        return b
    if event == "place":
        b = blank(0.12)
        thock(b, f * 1.3, 0.10, 1.0, q=2.2, decay=62.0, exc_ms=4.5, seed=111 + k)
        grains(b, 3, 0.05, 0.22, 260.0, 720.0, q=2.0, decay=250.0,
               seed=511 + k, bunch=0.6)
        tap(b, 0.010, 0.13, decay=230.0, seed=311 + k)
        return b
    b = blank(0.085)
    grains(b, 6, 0.05, 0.8, 240.0, 700.0, q=1.8, decay=230.0,
           seed=401 + k, bunch=0.6)
    return b


def grass(event, k):
    # Grain with a trace of soil under it. The rustle carries the material;
    # the body only says there is ground beneath.
    f = 1250.0 * (1.0 + 0.05 * (k - 1))
    if event == "break":
        b = blank(0.2)
        grains(b, 15, 0.15, 0.9, f * 0.7, f * 2.1, q=4.0, decay=230.0,
               seed=202 + k, bunch=0.7)
        thock(b, 215.0, 0.09, 0.4, q=2.2, decay=70.0, exc_ms=4.0, seed=102 + k)
        return b
    if event == "place":
        b = blank(0.12)
        grains(b, 9, 0.085, 0.85, f * 0.65, f * 1.8, q=4.0, decay=250.0,
               seed=212 + k, bunch=0.7)
        thock(b, 205.0, 0.07, 0.35, q=2.2, decay=90.0, seed=112 + k)
        return b
    b = blank(0.095)
    grains(b, 11, 0.06, 0.9, f * 0.8, f * 2.4, q=3.5, decay=270.0,
           seed=402 + k, bunch=0.85)
    return b


def wood_mat(event, k):
    f = 335.0 * (1.0 + 0.04 * (k - 1))
    if event == "break":
        b = blank(0.24)
        wood(b, f, 0.16, 1.0, q=5.0, decay=42.0, seed=103 + k)
        # Splinters: the tail that separates a break from a knock.
        grains(b, 7, 0.17, 0.3, 600.0, 1700.0, q=6.0, decay=200.0,
               start=0.03, seed=203 + k, bunch=0.5)
        tap(b, 0.015, 0.2, decay=170.0, seed=303 + k)
        return b
    if event == "place":
        b = blank(0.12)
        wood(b, f * 0.92, 0.10, 1.0, q=5.5, decay=62.0, seed=113 + k)
        return b
    b = blank(0.08)
    wood(b, f * 0.78, 0.065, 1.0, q=4.0, decay=95.0, seed=403 + k)
    return b


def leaves(event, k):
    # No body whatsoever. Pure crackle -- the moment anything solid appears
    # under it, it stops being leaves and starts being a bush hitting a wall.
    f = 2600.0 * (1.0 + 0.05 * (k - 1))
    if event == "break":
        b = blank(0.22)
        grains(b, 20, 0.18, 0.9, f * 0.7, f * 2.0, q=5.0, decay=300.0,
               seed=204 + k, bunch=0.8)
        return b
    if event == "place":
        b = blank(0.13)
        grains(b, 11, 0.095, 0.9, f * 0.65, f * 1.7, q=5.0, decay=320.0,
               seed=214 + k, bunch=0.8)
        return b
    b = blank(0.1)
    grains(b, 13, 0.07, 0.9, f * 0.6, f * 1.8, q=4.5, decay=330.0,
           seed=404 + k, bunch=0.9)
    return b


def snow(event, k):
    # Compression rather than impact: a lot of small grains low enough to sound
    # packed, plus a soft body that says the ground gave way slightly.
    f = 780.0 * (1.0 + 0.05 * (k - 1))
    if event == "break":
        b = blank(0.2)
        grains(b, 17, 0.15, 0.85, f * 0.6, f * 1.9, q=2.6, decay=240.0,
               seed=205 + k, bunch=0.7)
        thock(b, 152.0, 0.11, 0.45, q=2.0, decay=55.0, exc_ms=5.0, seed=105 + k)
        return b
    if event == "place":
        b = blank(0.12)
        grains(b, 10, 0.085, 0.8, f * 0.55, f * 1.6, q=2.6, decay=260.0,
               seed=215 + k, bunch=0.7)
        thock(b, 148.0, 0.08, 0.5, q=2.0, decay=75.0, seed=115 + k)
        return b
    b = blank(0.11)
    grains(b, 13, 0.075, 0.9, f * 0.5, f * 1.5, q=2.2, decay=250.0,
           seed=405 + k, bunch=0.75)
    return b


def metal(event, k):
    f = 505.0 * (1.0 + 0.03 * (k - 1))
    if event == "break":
        b = blank(0.3)
        wood(b, f, 0.28, 1.0, q=14.0, decay=13.0, seed=106 + k,
             modes=METAL_MODES)
        tap(b, 0.015, 0.28, decay=160.0, seed=306 + k)
        return b
    if event == "place":
        b = blank(0.16)
        wood(b, f * 0.9, 0.14, 1.0, q=10.0, decay=32.0, seed=116 + k,
             modes=METAL_MODES)
        tap(b, 0.010, 0.18, decay=200.0, seed=316 + k)
        return b
    b = blank(0.09)
    wood(b, f * 1.7, 0.07, 1.0, q=8.0, decay=68.0, seed=406 + k,
         modes=METAL_MODES)
    return b


def glass(event, k):
    f = 1450.0 * (1.0 + 0.03 * (k - 1))
    if event == "break":
        b = blank(0.28)
        thock(b, f * 0.62, 0.10, 0.7, q=11.0, decay=45.0, exc_ms=1.5,
              seed=107 + k)
        # The tinkle, which is what actually sells breaking glass. The crack
        # itself is almost incidental.
        grains(b, 14, 0.22, 0.95, 1900.0, 6200.0, q=15.0, decay=62.0,
               start=0.02, seed=207 + k, bunch=0.45)
        return b
    if event == "place":
        b = blank(0.13)
        wood(b, f, 0.11, 1.0, q=10.0, decay=54.0, seed=117 + k,
             modes=GLASS_MODES)
        tap(b, 0.008, 0.14, decay=220.0, seed=317 + k)
        return b
    b = blank(0.075)
    thock(b, f * 1.5, 0.055, 1.0, q=5.0, decay=125.0, exc_ms=1.2, seed=407 + k)
    # A single high resonance on its own is a beep. Three specks around it turn
    # it back into something being stepped on.
    grains(b, 4, 0.04, 0.45, 2400.0, 5200.0, q=8.0, decay=200.0,
           seed=507 + k, bunch=0.7)
    return b


MATERIALS = {
    "stone": stone,
    "dirt": dirt,
    "grass": grass,
    "wood": wood_mat,
    "leaves": leaves,
    "snow": snow,
    "metal": metal,
    "glass": glass,
}


def main():
    os.makedirs(OUT, exist_ok=True)
    print("writing to", OUT)
    n = 0
    for name in sorted(MATERIALS):
        fn = MATERIALS[name]
        for event in ("break", "place", "step"):
            for k in range(1, TAKES[event] + 1):
                buf = fn(event, k)
                write_wav(os.path.join(OUT, "%s_%s_%d.wav" % (event, name, k)),
                          buf, PEAK[event])
                n += 1
    print("%d files" % n)


if __name__ == "__main__":
    main()
