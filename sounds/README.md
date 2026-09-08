# Sound

Everything the game plays goes through the `Audio` autoload
([scripts/audio.gd](../scripts/audio.gd)). It owns the buses, a pool of
players, and a catalogue that says how each sound is allowed to behave.

## Adding sounds

**Drop WAVs into `sounds/world/` with the names below and they start playing.
There is no code to change.** A catalogue entry whose files are all missing is
simply silent, and the game prints what is still missing at startup:

```
audio: 104 file(s) not recorded yet -- res://sounds/world (104)
```

Numbered takes are a ceiling, not a requirement — `step_grass` lists six, and if
you record three, those three are what plays. More takes is better for anything
that fires often; footsteps are the extreme case.

Format: **16-bit mono WAV**. Mono matters — a stereo file cannot be positioned
in 3D. Trim the silence off the front; a sound with 40 ms of dead air in front
of it is a sound that arrives late.

Don't bother pitch-shifting takes to make them differ. The catalogue already
detunes every play by up to ±15–20%, which is where most of the variation
comes from.

### What to record

Eight materials — `stone`, `dirt`, `grass`, `wood`, `leaves`, `snow`, `metal`,
`glass` — times three events:

| | takes | filenames |
|---|---|---|
| break | 4 | `break_<material>_1.wav` … `_4.wav` |
| place | 3 | `place_<material>_1.wav` … `_3.wav` |
| step | 6 | `step_<material>_1.wav` … `_6.wav` |

So `sounds/world/break_stone_1.wav`, `sounds/world/step_grass_4.wav`, and so on.

Every block in the game maps to one of those eight. Slabs and stairs inherit
from the block they were cut out of, and anything not in the table falls back to
`stone` — so a new block makes a plausible noise the day it is added.

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
