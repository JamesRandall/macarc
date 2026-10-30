# Floppy drive sounds

MAME's recordings of a 3.5" floppy drive (`35_*.wav`: the motor starting,
running and stopping, with and without a disc, a head step, and seeks at
2, 6, 12 and 20 ms a step), from
https://github.com/mamedev/mame/tree/master/samples/floppy by way of b2
and MacBeeb. They're under CC0 1.0 (`LICENSE-CC0`).

`DiscDriveSounds.load(folder:)` reads them; the floppy controllers' motor
and seek events play them (`DiscDriveNoise.swift`), mixed into VIDC's sound.
