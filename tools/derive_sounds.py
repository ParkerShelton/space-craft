#!/usr/bin/env python3
"""Builds break, place and mine WAVs out of the step recordings in sounds/world/.

Record the footsteps, get all four events. The game can already do a version of
this at playback time, but only with the one tool a playing sample has: pitch.
Doing it offline lifts that limit -- a file can have layers the source never
had, which is where the pop and the oomph come from.

Each event is the same recording wearing a different shape:

  break -- pitched well down (longer as well as lower, since on a sample those
           are the same knob), with a sharp synthetic POP on the front so the
           moment the block gives way has an edge to it, then two quieter
           echoes of the material itself as debris.
  place -- pitched up and shortened, with a low thump under it for OOMPH: the
           weight of a block being set down, which a footstep recording has
           none of.
  mine  -- pitched slightly down, short and quiet, and deliberately plain. It
           repeats every 190 ms for as long as you hold the button, so anything
           characterful in it becomes maddening inside ten seconds.

    python tools/derive_sounds.py            # report only, changes nothing
    python tools/derive_sounds.py --write    # actually write the files

Running tools/prep_recordings.py first is worth it but not required: this trims
its own source and normalises its own output, so an unprepped six-second take
with one hit at the front still yields a sensible break.

Generated filenames are listed in sounds/world/.generated so prep_recordings.py
knows to leave them alone, and so re-running here overwrites its own output
rather than piling up. Record a real break_wood_1.wav any time and it simply
replaces the built one.

Stdlib only, plus the synthesis primitives in synth.py.
"""

import argparse
import os
import struct
import sys
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import synth

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORLD = os.path.join(ROOT, "sounds", "world")
MANIFEST = os.path.join(WORLD, ".generated")

# --- the knobs ----------------------------------------------------------------
#
# Pitch is the big one. Anything subtle leaves the events sounding like the same
# sound at three volumes; these are far enough apart that a break stops
# resembling the step it came from, which is the point rather than a side
# effect -- nobody hears the two side by side.
BREAK_PITCH = 0.50      # over an octave down, and 100% longer with it
PLACE_PITCH = 1.70      # and 41% shorter
MINE_PITCH = 0.88

# How much synthetic layer to mix over the real recording, 0 for none. These are
# the two the ear notices most, so they are the two worth turning first.
POP = 0.34              # break: the crack at the instant it gives way
OOMPH = 0.40            # place: low weight under the contact

TAKES = {"break": 4, "place": 3, "mine": 3}
PEAK = {"break": 0.82, "place": 0.76, "mine": 0.52}
MINE_MAX_MS = 190       # it repeats on a 190 ms throttle; longer just overlaps


def read_wav(path):
	with wave.open(path, "rb") as w:
		rate, ch, width, n = (w.getframerate(), w.getnchannels(),
			w.getsampwidth(), w.getnframes())
		raw = w.readframes(n)
	if width != 2:
		raise ValueError("only 16-bit WAV supported")
	x = list(struct.unpack("<%dh" % (len(raw) // 2), raw))
	if ch > 1:
		x = [sum(x[i:i + ch]) // ch for i in range(0, len(x) - ch + 1, ch)]
	return [float(v) for v in x], rate


def write_wav(path, x, rate, peak):
	hi = max((abs(v) for v in x), default=0.0) or 1.0
	k = peak * 32768.0 / hi
	with wave.open(path, "wb") as w:
		w.setnchannels(1)
		w.setsampwidth(2)
		w.setframerate(rate)
		w.writeframes(b"".join(
			struct.pack("<h", max(-32768, min(32767, int(v * k)))) for v in x))


def trim(x, rate, gate=0.03, lead_ms=6, tail_ms=45):
	"""Cut to where the sound actually is.

	Done here as well as in prep_recordings.py on purpose: this script must not
	depend on that one having been run. A six-second take with one hit at the
	front would otherwise become a thirteen-second break.
	"""
	peak = max((abs(v) for v in x), default=0.0)
	if peak == 0.0:
		return x
	g = gate * peak
	a = next((i for i, v in enumerate(x) if abs(v) > g), 0)
	b = len(x) - next((i for i, v in enumerate(reversed(x)) if abs(v) > g), 0)
	a = max(0, a - int(lead_ms * rate / 1000))
	b = min(len(x), b + int(tail_ms * rate / 1000))
	return x[a:b]


def shift(x, ratio):
	"""Resample by linear interpolation: lower ratio is lower AND longer."""
	m = int(len(x) / ratio)
	out = [0.0] * m
	for i in range(m):
		t = i * ratio
		a = int(t)
		f = t - a
		s0 = x[a] if a < len(x) else 0.0
		s1 = x[a + 1] if a + 1 < len(x) else 0.0
		out[i] = s0 + (s1 - s0) * f
	return out


def mix(dst, src, at, gain):
	for i, v in enumerate(src):
		j = at + i
		if 0 <= j < len(dst):
			dst[j] += v * gain


def fade_tail(x, rate, ms=18):
	f = min(int(ms * rate / 1000), len(x) // 3)
	for i in range(f):
		x[len(x) - 1 - i] *= i / float(f)
	return x


def level(x):
	return max((abs(v) for v in x), default=0.0) / 32768.0


def build_break(step, rate, k):
	"""Pitched down, popped, and given debris made of the material itself."""
	# Vary the shift a little per take rather than the whole recipe: four takes
	# of one block breaking, not four different blocks.
	body = shift(step, BREAK_PITCH * (1.0 + 0.035 * (k - 2)))
	out = body + [0.0] * int(0.12 * rate)

	# The POP. A short high transient plus a mid resonance, both from synth.py,
	# sitting right on the front. A recording of a footstep has no crack in it,
	# and a crack is most of what "it just broke" sounds like -- this is the
	# layer the runtime version could not add.
	pop = synth.blank(0.09)
	synth.tap(pop, 0.014, 1.0, decay=150.0, seed=200 + k)
	synth.thock(pop, 430.0 * (1.0 + 0.05 * (k - 2)), 0.085, 0.85, q=4.5,
		decay=60.0, exc_ms=1.6, seed=210 + k)
	mix(out, [v * 32768.0 for v in pop], 0, POP)

	# Debris: the same material again, quieter, higher and late. Using the real
	# recording rather than synthetic grain keeps the texture honest -- rock
	# debris sounds like that rock.
	mix(out, shift(body, 1.35), int(0.055 * rate), 0.34)
	mix(out, shift(body, 0.92), int(0.115 * rate), 0.20)
	return fade_tail(out, rate, 40)


def build_place(step, rate, k):
	"""Pitched up and shortened, with weight put under it."""
	body = shift(step, PLACE_PITCH * (1.0 + 0.03 * (k - 2)))
	out = body + [0.0] * int(0.10 * rate)

	# The OOMPH. A short low sine is the whole trick: 70 ms of 130 Hz is heard
	# as a block landing, not as a note, because it is over before the ear can
	# name a pitch. A footstep recording has nothing this low in it.
	low = synth.blank(0.11)
	synth.thump(low, 132.0 * (1.0 + 0.04 * (k - 2)), 0.075, 1.0, decay=42.0,
		bend=0.72)
	# A little contact click on top so the weight has something to hang off.
	synth.tap(low, 0.008, 0.28, decay=230.0, seed=300 + k)
	mix(out, [v * 32768.0 for v in low], 0, OOMPH)
	return fade_tail(out, rate, 25)


def build_mine(step, rate, k):
	"""Short, quiet, plain. It is going to play three hundred times."""
	body = shift(step, MINE_PITCH * (1.0 + 0.05 * (k - 2)))
	body = body[:int(MINE_MAX_MS * rate / 1000)]
	return fade_tail(body, rate, 22)


BUILD = {"break": build_break, "place": build_place, "mine": build_mine}


def steps_for(material):
	out = []
	for f in sorted(os.listdir(WORLD)):
		if f.startswith("step_%s_" % material) and f.lower().endswith(".wav"):
			out.append(os.path.join(WORLD, f))
	return out


def materials():
	found = set()
	for f in os.listdir(WORLD):
		if f.startswith("step_") and f.lower().endswith(".wav"):
			parts = f[:-4].split("_")
			if len(parts) >= 3:
				found.add("_".join(parts[1:-1]))
	return sorted(found)


def main():
	ap = argparse.ArgumentParser(description=__doc__)
	ap.add_argument("--write", action="store_true",
		help="write the files (without this, only reports)")
	ap.add_argument("--only", help="one material, e.g. grass")
	args = ap.parse_args()

	mats = materials()
	if args.only:
		mats = [m for m in mats if m == args.only]
	if not mats:
		print("no step_<material>_*.wav found in", WORLD)
		return 1

	generated = []
	print("%-24s %8s  %s" % ("file", "length", "from"))
	print("-" * 62)
	for mat in mats:
		srcs = steps_for(mat)
		for ev in ("mine", "break", "place"):
			for k in range(1, TAKES[ev] + 1):
				src = srcs[(k - 1) % len(srcs)]
				step, rate = read_wav(src)
				step = trim(step, rate)
				# synth's helpers read this module-level rate, so match the
				# recording rather than resampling it to suit them.
				synth.RATE = rate
				out = BUILD[ev](step, rate, k)
				name = "%s_%s_%d.wav" % (ev, mat, k)
				print("%-24s %6d ms  %s" % (name, len(out) * 1000 // rate,
					os.path.basename(src)))
				if args.write:
					write_wav(os.path.join(WORLD, name), out, rate, PEAK[ev])
				generated.append(name)

	print("-" * 62)
	if args.write:
		with open(MANIFEST, "w") as f:
			f.write("# written by tools/derive_sounds.py -- safe to delete\n")
			f.write("\n".join(sorted(generated)) + "\n")
		print("%d file(s) written to sounds/world/, listed in .generated"
			% len(generated))
	else:
		print("%d file(s) would be written. Re-run with --write." % len(generated))
	return 0


if __name__ == "__main__":
	sys.exit(main())
