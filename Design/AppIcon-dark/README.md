# AppIcon dark variants (source)

Xcode 26 `actool` treats luminosity/dark children inside a classic multi-size
macOS `AppIcon.appiconset` as **unassigned** (Ambiguous Content warning).

These PNGs are the dark artwork (same sizes as the light AppIcon slots). To
ship appearance-aware Dock icons later, import them via **Icon Composer**
(`.icon`) or a single-size macOS 15+ icon pipeline — do not drop them back
into `AppIcon.appiconset` as per-size `appearances: dark` entries.
