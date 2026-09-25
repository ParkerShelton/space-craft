#!/usr/bin/env python3
"""Generates the smithing sounds as 16-bit mono WAVs into sounds/forge/.

A hammer on hot metal on an anvil: the one struck sound in this game that is
SUPPOSED to ring. A block breaking should not sing, which is why the world
sounds were never synthesised this way -- but an anvil is a bell with a flat
top, and the ring is most of what makes striking one satisfying.

Two sounds. The strike: a sharp tick where the hammer lands, a short thud of
weight under it, and the anvil ringing at a few unrelated frequencies so it
reads as steel rather than as a note. And the blow that ruins a piece: the
ring choked off, with a dry crunch where it splits.

Stdlib only. Re-run it after editing a recipe:

    python tools/make_forge_sounds.py

Drop a recording over either file with the same name and it plays instead.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from synth import blank, grains, ring, tap, thock, thump, write_wav

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "sounds", "forge")


def write(name, buf, peak=0.72):
    write_wav(os.path.join(OUT, name + ".wav"), buf, peak)


def main():
    os.makedirs(OUT, exist_ok=True)
    print("writing to", OUT)

    # --- strike --------------------------------------------------------------
    # The ring's partials are steel-bar ratios (1, 2.76, 5.40), which never
    # fuse into one pitch. Its decay is short enough that a quick run of blows
    # overlaps into a rhythm instead of a wash.
    b = blank(1.1)
    tap(b, 0.03, 0.7, decay=260.0)
    thump(b, 110.0, 0.08, 0.5, decay=40.0)
    thock(b, 2300.0, 0.12, 0.35, q=10.0, decay=45.0, impulse=0.6)
    ring(b, [1180.0, 1180.0 * 2.76, 1180.0 * 5.40], 1.0, 0.55, decay=6.5)
    ring(b, [1740.0, 1740.0 * 2.76], 0.6, 0.18, decay=11.0)
    write("strike", b)

    # --- scrap ---------------------------------------------------------------
    # The same blow, but the metal gives: almost no ring, and the crackle of it
    # tearing.
    b = blank(0.7)
    tap(b, 0.03, 0.6, decay=220.0)
    thump(b, 90.0, 0.1, 0.6, decay=30.0)
    thock(b, 640.0, 0.2, 0.4, q=4.0, decay=22.0)
    ring(b, [900.0, 900.0 * 2.76], 0.25, 0.15, decay=30.0)
    grains(b, 26, 0.35, 0.3, 700.0, 3000.0, q=3.5, decay=200.0, start=0.01, seed=7,
           bunch=0.4)
    write("scrap", b)

    # --- press ---------------------------------------------------------------
    # The ram landing: a lot of weight arriving at once, a flat metal slap on
    # top, and the frame ringing briefly low. Heavier and duller than the
    # anvil -- it is a machine, not a blow.
    b = blank(0.9)
    thump(b, 58.0, 0.3, 1.0, decay=11.0)
    tap(b, 0.04, 0.8, decay=180.0)
    thock(b, 320.0, 0.2, 0.55, q=4.5, decay=18.0)
    ring(b, [410.0, 410.0 * 2.76, 410.0 * 5.4], 0.7, 0.28, decay=7.0)
    write("press_stamp", b)

    # The ram stopping short: a dead clunk and a rattle, no ring at all.
    b = blank(0.5)
    thump(b, 80.0, 0.15, 0.6, decay=26.0)
    thock(b, 240.0, 0.12, 0.5, q=3.0, decay=30.0)
    grains(b, 8, 0.15, 0.15, 400.0, 1400.0, q=3.0, decay=160.0, start=0.02, seed=5)
    write("press_miss", b)


if __name__ == "__main__":
    main()
