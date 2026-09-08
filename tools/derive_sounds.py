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
import math
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
# Pitch pulls two ways at once, and this is the whole design problem.
#
# Far from 1.0 is what makes two events sound DIFFERENT. Near 1.0 is what keeps
# them sounding like the MATERIAL. Push a place up to 1.7x and it is
# unmistakably not a footstep -- and also unmistakably not grass any more,
# because a rustle sped up by two thirds is just hiss. Both complaints are real
# and they are the same knob.
#
# So pitch is used sparingly now and the separation is carried by things that
# do not touch identity: length, and what is layered on top. A place is barely
# shifted at all and gets its weight from a thump; a break is shifted enough to
# feel heavier but not so far it stops being the material, and gets its edge
# from a transient.
# A break RISES, and it rises from about where the mining left off. Pitch going
# up reads as release -- the thing you were working at finally letting go --
# which is the one job pitch does better than any layer. It also means the
# break lifts away from the chipping sound instead of sitting in the same place
# as it, so the two are separated by direction rather than only by size.
BREAK_PITCH_FROM = 0.92     # near the chip it interrupts
BREAK_PITCH_TO = 1.30       # and up, over the length of the sound
# 1.55 with the debris climbing behind it put the last third of a grass break
# at a 9 kHz spectral centroid, which is a whistle rather than a release. The
# rise has to be heard as a direction, not as a trip to the top of the range.
# A place goes the other way: down is weight, and setting a block down is the
# heaviest thing you do to one.
PLACE_PITCH = 0.85
MINE_PITCH = 0.80

# How much synthetic layer to mix over the real recording, 0 for none. With
# pitch doing less, these do more, so they are the first things to turn.
# Now genuinely fractions OF THE MATERIAL, since the body is normalised first.
# 0.45 means "the added layer peaks at about half what the recording does",
# which is audible as weight without covering the recording up.
POP = 0.50              # break: the crack at the instant it gives way
OOMPH = 0.45            # place: low weight under the contact

TAKES = {"break": 4, "place": 3, "mine": 3}
PEAK = {"break": 0.86, "place": 0.76, "mine": 0.30}

# Mining is a different KIND of sound, not a quieter version of the same one.
# It is the chipping away, and it has to still be going on when the block
# finally gives -- so it is short, dull and small, and the break lands on top
# of it as an obviously bigger event.
MINE_MAX_MS = 80
MINE_LOWPASS = 2000.0


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


def lowpass(x, rate, fc):
	"""One-pole lowpass. Takes the edge off without changing what it is.

	Used to make mining dull rather than quiet. Turning a sound down keeps all
	its detail and just moves it away; filtering it takes the detail out, which
	is what "muffled, still working on it" actually sounds like.
	"""
	a = math.exp(-2.0 * math.pi * fc / rate)
	out = []
	prev = 0.0
	for v in x:
		prev = v * (1.0 - a) + prev * a
		out.append(prev)
	return out


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


def norm(x, target=0.85):
	"""Scale to a known peak.

	The layers below are mixed as FRACTIONS of the material, so the material
	has to be at a known level first. Skipping this is how a place ended up 98%
	below 200 Hz: the grass take peaks at 0.05, the thump was at a fixed 0.62,
	so the synthetic layer was twelve times the recording and buried the very
	thing that makes it sound like grass.
	"""
	hi = max((abs(v) for v in x), default=0.0)
	if hi <= 0.0:
		return x
	k = target * 32768.0 / hi
	return [v * k for v in x]


def glide(x, r0, r1):
	"""Resample with a ratio that travels from r0 to r1.

	A flat shift moves a sound; a glide gives it a direction. That direction is
	the whole point here -- a break that starts near the pitch of the chipping
	and climbs away from it says "released" in a way no fixed pitch does.
	"""
	out = []
	t = 0.0
	guess = max(1, int(len(x) / ((r0 + r1) * 0.5)))
	while t < len(x) - 1:
		f = min(1.0, len(out) / float(guess))
		r = r0 * ((r1 / r0) ** f)
		a = int(t)
		frac = t - a
		out.append(x[a] + (x[a + 1] - x[a]) * frac)
		t += r
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
	# Takes vary in how far they climb rather than in structure: four takes of
	# one block breaking, not four different blocks.
	wobble = 1.0 + 0.05 * (k - 2)
	body = norm(glide(step, BREAK_PITCH_FROM, BREAK_PITCH_TO * wobble))
	out = body + [0.0] * int(0.12 * rate)

	# The POP. A short high transient plus a mid resonance, both from synth.py,
	# sitting right on the front. A recording of a footstep has no crack in it,
	# and a crack is most of what "it just broke" sounds like -- this is the
	# layer the runtime version could not add.
	pop = synth.blank(0.11)
	synth.tap(pop, 0.016, 1.0, decay=130.0, seed=200 + k)
	# The transient rises too, so the crack agrees with the body instead of
	# anchoring it back down.
	synth.thock(pop, 520.0 * (1.0 + 0.05 * (k - 2)), 0.10, 0.9, q=4.5,
		decay=52.0, exc_ms=1.6, bend=1.7, seed=210 + k)
	mix(out, [v * 32768.0 for v in pop], 0, POP)

	# Debris: the same material again, quieter and late, and climbing further
	# with the rest of it. Using the real recording rather than synthetic grain
	# keeps the texture honest -- rock debris sounds like that rock.
	mix(out, shift(body, 1.12), int(0.050 * rate), 0.30)
	mix(out, shift(body, 1.28), int(0.105 * rate), 0.18)
	return fade_tail(out, rate, 40)


def build_place(step, rate, k):
	"""Pitched up and shortened, with weight put under it."""
	body = norm(shift(step, PLACE_PITCH * (1.0 + 0.03 * (k - 2))))
	out = body + [0.0] * int(0.10 * rate)

	# The OOMPH. A short low sine is the whole trick: 75 ms of 120 Hz is heard
	# as a block landing, not as a note, because it is over before the ear can
	# name a pitch. A footstep recording has nothing this low in it, and with
	# the body now pitched DOWN the two agree instead of fighting.
	low = synth.blank(0.11)
	synth.thump(low, 120.0 * (1.0 + 0.04 * (k - 2)), 0.08, 1.0, decay=38.0,
		bend=0.70)
	# A little contact click on top so the weight has something to hang off.
	synth.tap(low, 0.008, 0.28, decay=230.0, seed=300 + k)
	mix(out, [v * 32768.0 for v in low], 0, OOMPH)
	return fade_tail(out, rate, 25)


def build_mine(step, rate, k):
	"""A chip, not a hit.

	Kept to the first 80 ms -- the attack and nothing else -- then muffled. The
	point is that this can be going on when the block finally breaks and the
	break still lands as an obviously bigger, brighter, longer event. A quieter
	copy of the same sound would not do that; it would just be the same sound.
	"""
	body = norm(shift(step, MINE_PITCH * (1.0 + 0.05 * (k - 2))))
	body = body[:int(MINE_MAX_MS * rate / 1000)]
	body = lowpass(body, rate, MINE_LOWPASS)
	return fade_tail(body, rate, 18)


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
