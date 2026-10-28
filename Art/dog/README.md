# Dog mascot

`approved-concept.png` is the user-approved character reference: a cream, long-legged dog with pale tan floppy ears, brown eyes and a pink-brown nose. No harness, leash or collar. Sheets were generated from that reference in a hand-drawn cartoon style.

Each `*-sheet.png` is a 1024×1024 green-screen image with four 512×512 cells in reading order. Animation groups keep a shared crop and scale, with a transparent perimeter in the output.

- `run`, `sniff`: existing working activities, redrawn with the new dog.
- `splash`, `dig`, `tug`, `roll`, `fetch`: additional working activities.
- `flip`: one-shot Space-change somersault: preparation, tucked take-off, inverted rotation, landing (one second total).
- `blocked`: standing dog holding a readable STOP sign, with gentle head/tail movement and a blink.
- `states`: sleeping (top left), unavailable/head tilt (top right), celebrating (bottom left), still working (bottom right).

Regenerate transparent 256×256 frames from the repository root:

```sh
swift scripts/prepare-corgi-assets.swift
swift run OverlaySelfCheck
```

The preparation script and `Sources/OverlayApp/Resources/Corgi` retain their legacy names. The app uses only the new dog frames; the old `Art/corgi` sheets are historical and are not inputs to this pipeline.

Inspect `.build/corgi-contact-sheet.png` on dark and light backgrounds after regeneration. The app keeps its 96 pt mascot footprint and existing layout/position preferences. Reduce Motion uses a still standing dog during work and a still STOP pose when blocked.
