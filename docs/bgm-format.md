# Background music format (DATA/SD_BGM.DAT)

Written by `tools/extract.py` (`export_bgm`, run by `--audio` and by the default run). Verified against the disc: all 57 packages parse, every VAB's size equals its header plus its VAG sizes, all 60 sequences start with a valid tag, all 736 VAG bodies end on an end flag and none is silent, and every tone's VAG number resolves.

Sector size is 2048 bytes. Offsets are bytes unless stated.

## Track ids

The game plays a track with a 16-bit id, for example 0x70E0, 0x72D0, 0x7300, 0x7350. The command adds the class nibble 0x7000, so the id's bits are:

- bits 4..11: the package index (`pkg`, 0..255), which is an entry in the package table.
- bits 0..3: the sequence index within that package (`seq`, 0..15).
- bits 12..15: the class nibble (0x7 for all music ids).

The export key is `key = (pkg << 4) | seq`, the id's low 12 bits, written as three hex digits. Each track lives in `assets/audio/bgm/<key>/`, for example key `0E0` is game id 0x70E0. `assets/audio/bgm/index.json` lists every track with its game id, package, sequence, timebase, tempo and file names, plus one entry per package.

## SD_BGM.DAT layout

The file is a set of packages. Each package has two parts, stored in separate regions:

1. The **bodies**: the VAG sample bodies of the package, back to back, starting at sector `body_sector`.
2. The **header block**: `header_sectors` sectors starting at `header_sector`, holding the sequence records, the VAB header and the sequence data.

### Package table (sector 0, 256 entries of 8 bytes)

Entry `pkg` is at byte `pkg * 8`:

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | u8 | `header_offset` | Header block start, in sectors after `body_sector` |
| 1 | u8 | `header_sectors` | Header block length in sectors |
| 2 | u16 LE | `body_sector` | First sector of the VAG bodies |
| 4 | u32 LE | `spu_address` | SPU RAM address the VAG bodies are uploaded to |

So `header_sector = body_sector + header_offset`. Entries without a `pBAV` header at `header_sector * 2048 + 0x50` are empty (the table has 57 used entries, 0..56, and a bank-information block at entry 255 that is not a package).

### Header block (at `header_sector * 2048`)

| Offset | Size | Field |
|---|---|---|
| 0x00 | u16 BE | (unused here) |
| 0x02 | u16 BE | `count`: number of sequences (1 to 16) |
| 0x0C | u32 BE | SPU address of the VAG bodies (same as table entry field 4) |
| 0x10 + 4*i | u16 BE | Sequence `i` offset divided by 16 (the byte offset is value * 16 from the start of the block) |
| 0x50 | ... | VAB header (`pBAV`) |

The sequence data follows the VAB header, starting at the first record's offset (for example 0x1670 in package 0, exactly where the VAB header ends). A sequence runs from its record to the next record, or to the end of the header block for the last one. The export writes each sequence as `seq.bin` in exactly that span.

### Sequence chunk

The chunk starts with the tag bytes `70 51 45 53` (the SEQ word read little-endian; written `pQES` here). All offsets below are inside the chunk.

| Offset | Size | Field |
|---|---|---|
| 0x00 | 4 | Tag `pQES` |
| 0x04 | u32 BE | Header word (value 1 in every package checked; kept raw in tones.json as `sequence.header_word`) |
| 0x08 | u16 BE | Timebase (ticks per quarter note; 480 in every package checked) |
| 0x0A | u24 BE | Tempo: microseconds per quarter note (read as u32 BE, then shifted right 8) |
| 0x0E | u8 | One byte skipped by the reader before the events (value 5 in every package checked) |
| 0x0F | ... | Event stream |

BPM is `60000000 / tempo_us`. Every package checked gives a round BPM (59, 58, 280, 93, 79, 75, 110), which confirms the tempo field.

The event stream is MIDI-like: each event is a variable-length delta time followed by a status byte (running status allowed), channel messages (note, controller, program, pitch bend), meta events (`FF`) and SysEx (`F0`). The first event is at 0x0F with delta 0. The first end-of-track meta event (`FF 2F 00`) is recorded in tones.json as `first_end_of_track`, but a sequence may loop or continue past it, so the player must not stop there unless the event semantics say so.

### VAB header (at `header_sector * 2048 + 0x50`)

Standard PS1 VAB layout, little-endian:

- VabHdr, 0x20 bytes: `pBAV` (+0), version (+4), id (+8), `fsize` (+0x0C; the VAB size, see note below), reserved (+0x10), `ps` (+0x12: program count), `tn` (+0x14: tone count), `vs` (+0x16: VAG count; VAG numbers run 1 to `vs`), master volume, master pan, attr1, attr2, reserved.
- ProgAtr[128], 16 bytes each, at +0x20: `tones` (count of tones in the program), `mvol`, `prior`, `mode`, `mpan`, reserved, `attr` (u16 at +6), reserved.
- VagAtr[program][16], 32 bytes each, at +0x820 + `program * 0x200` + `tone * 0x20` for `tone < tones`:

  | Offset | Size | Field |
  |---|---|---|
  | 0 | u8 | priority |
  | 1 | u8 | mode |
  | 2 | u8 | volume |
  | 3 | u8 | pan (0x40 is centre) |
  | 4 | u8 | centre note (the note at which the VAG plays at its native rate) |
  | 5 | s8 | fine shift (cents-like fine tuning of the centre note) |
  | 6 | u8 | min note |
  | 7 | u8 | max note |
  | 8 | u8 | vibrato width |
  | 9 | u8 | vibrato time |
  | 10 | u8 | portamento width |
  | 11 | u8 | portamento time |
  | 12 | u8 | pitch bend min |
  | 13 | u8 | pitch bend max |
  | 14 | 2 | reserved |
  | 16 | u16 LE | adsr1 (SPU envelope register) |
  | 18 | u16 LE | adsr2 (SPU envelope register) |
  | 20 | s16 LE | prog (the program the tone belongs to) |
  | 22 | s16 LE | vag: the VAG number the tone plays, 1-based (0 means no sample) |
  | 24 | 8 | reserved |

- VAG size table at `0x50 + header_size - 0x200`: 256 entries of u16 LE, each the size of one VAG body in units of 8 bytes. Entry 0 is always 0. VAG `n` (1 to `vs`) has size `table[n] * 8`.

The VAB header size is `(ps << 9) + 0xA20` bytes.

### VAG bodies (at `body_sector * 2048`)

The bodies are the VAGs in number order, back to back with no headers: VAG 1 at `body_sector * 2048`, VAG 2 right after it, and so on. Sizes come from the size table. Their total is `sum(table) * 8`. Upload to SPU RAM: VAG `n` goes to `spu_address + sum of the sizes of VAGs 1..n-1`.

Each body is PS1 ADPCM in 16-byte frames: byte 0 is `(filter << 4) | shift`, byte 1 is the flags. Flags: bit 0 = end (this frame is the last one), bit 1 = repeat (set on the end frame of a looping sample, which jumps back to the loop start; most frames of a looping sample also carry it and it has no effect there), bit 2 = loop start. Each frame decodes to 28 samples. Filters and the decode formula are the ones used by the sound-effect export (`_adpcm` in `tools/extract.py`).

The bank volume is the byte after the `VolInfo` signature at SD_BGM.DAT offset 0x7F8 (the bank-information entry at the end of the package table; 150 on this disc). The game's music master level is the bank volume times the fade and volume levels, so tones.json carries it as `bank_volume` (the driver's default 0xD2 is used only when the block is missing). Voice gain is the SPU volume register doubled by the hardware, with the master at 0x3FFF (x1.0).

Loop points, in samples, are recorded per VAG in tones.json. The repeat flag (bit 1) is set on most frames of a looping sample, so it only counts on the end frame: a VAG loops when its end frame has bit 1 (and then `loop_end` is the VAG's sample count), and it returns to `loop_start`, the first sample of the first frame with the loop-start flag (bit 2), or sample 0 when there is none. A VAG whose end frame lacks bit 1 is one-shot, and both loop fields are `null`.

Check: the VAB `fsize` equals the VAB header size plus the sum of VAG 1..`vs` sizes in every package.

## Exported layout

```
assets/audio/bgm/
  index.json                 class nibble, sample rate, every track (game id, package, sequence, timebase, tempo, bpm, file names), and every package
  <key>/                     key = three hex digits, package << 4 | sequence (e.g. 0E0)
    seq.bin                  the raw sequence chunk from its tag to the next record (or the end of the header block)
    tones.json               the package's programs and tones (every VagAtr field), the VAG table with spu_address, file, and loop points, and this track's sequence header
    samples/vag_NNN.wav      each VAG decoded to 16-bit mono at 44100 Hz, NNN is the VAG number
```

Packages with two sequences (packages 4, 46 and 47) share the same bodies and VAB; their samples and tones.json are written into each track's folder.

Sample WAVs are the native decode at the base rate. The player plays a VAG at the tone's centre note and fine shift, and loops it on the loop points.
