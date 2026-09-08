# Sound

Everything the game plays goes through the `Audio` autoload
([scripts/audio.gd](../scripts/audio.gd)). It owns the buses, a pool of
players, and a catalogue that says how each sound is allowed to behave.

## Adding sounds

**Drop WAVs into `sounds/world/` with the names below and they start playing.
There is no code to change.** The triggers are already wired: breaking, placing
and footsteps all call into the catalogue, and a catalogue entry whose files are
all missing is simply silent rather than an error.

Numbered takes are a ceiling, not a requirement -- `step_grass` lists six, and if
you record three, those three are what plays. More takes is better for anything
that fires often; footsteps are the extreme case.

### File format

**16-bit mono WAV, 44.1 kHz.** Three things about that matter:

- **Mono, not stereo.** A stereo file cannot be positioned in 3D. This is the
  one that silently ruins a recording session.
- **WAV, not OGG or MP3.** These are short and fire constantly, and WAV needs no
  decoding per play. Use OGG only for music and long ambience.
- **Trim the front.** A sound with 40 ms of dead air in front of it is a sound
  that arrives late, and it will feel like input lag rather than like a bad
  recording.

Don't pitch-shift takes to make them differ. The catalogue already detunes every
play by up to +/-15-20%, which is where most of the variation comes from.

### Naming

Eight materials -- `stone`, `dirt`, `grass`, `wood`, `leaves`, `snow`, `metal`,
`glass` -- times three events:

| event | takes | filenames | fires when |
|---|---|---|---|
| break | 4 | `break_<material>_1.wav` ... `_4.wav` | a block or eighth-block is removed |
| place | 3 | `place_<material>_1.wav` ... `_3.wav` | a block or eighth-block is added |
| step | 6 | `step_<material>_1.wav` ... `_6.wav` | once per dip of the walk cycle |

So `sounds/world/break_stone_1.wav`, `sounds/world/step_grass_4.wav`, and so on.

Every block in the game maps to one of those eight. Slabs and stairs inherit
from the block they were cut out of, and anything not in the table falls back to
`stone` -- so a new block makes a plausible noise the day it is added.

Break, place and step are three different performances, not one sound at three
volumes. A break is destructive and has a tail; a place is a firm set-down,
shorter and softer; a step is the quietest and quickest of the three. Record
them differently or all three will sound like the same event.

### Checking your work

`Audio.missing_report()` returns what is still un-recorded:

```
audio: 104 file(s) not recorded yet -- res://sounds/world (104)
```

Printing it on startup in a debug build is a one-liner in `Main._ready`, and
worth having while you are recording.

Breaking and placing work in co-op without anything extra: the sound hangs off
the single point every block edit passes through, so another player's mining is
audible at the place it happened. Footsteps are local to your own player only.

### Foley notes

A phone in a quiet closet gets you most of the way. Classic voxel-game sources:

- **stone** — two bricks or rocks knocked together
- **dirt** — a bag of potting soil, punched
- **grass / steps** — dry rice or cat litter in a bowl, squeezed
- **wood** — dry pasta or celery snapped
- **leaves** — a handful of crumpled paper or actual dry leaves
- **snow** — cornstarch in a bag, squeezed slowly
- **glass** — a dropped jar lid; ice cubes in a glass
- **metal** — a wrench tapped on a pipe or radiator

## The UI sounds

`sounds/ui/` is generated, not recorded — see
[tools/make_ui_sounds.py](../tools/make_ui_sounds.py). Menu blips are the one
category where synthetic is the *right* character, and the one category you want
dead consistent across a hundred presses a session.

Re-run it after editing a recipe:

```bash
python tools/make_ui_sounds.py
```

To replace any of them with something recorded, just overwrite the WAV — the
catalogue only cares about the filename.
