# Third-party notices

Steppe itself is MIT licensed (see `LICENSE`). It uses or downloads the following third-party software.

## Shipped inside Steppe.app

| Component | License | Notes |
| --- | --- | --- |
| [Sparkle](https://sparkle-project.org) | MIT (with bundled components under their own permissive licenses; see the framework's `LICENSE`) | In-app updates |
| [libogg 1.3.5](https://xiph.org/ogg/), [libvorbis 1.3.7](https://xiph.org/vorbis/) | BSD-3-Clause, © Xiph.Org Foundation | Compiled from the official sources into the Windows DLLs in `Native/vorbis-fast`; full notices in `Native/vorbis-fast/THIRD_PARTY.md` |

## Downloaded on the user's Mac at install time (not redistributed by Steppe)

| Component | Source | License |
| --- | --- | --- |
| Wine 10.0 engine ("Sikarugir" build) | [Sikarugir-App/Engines](https://github.com/Sikarugir-App/Engines) | LGPL-2.1-or-later (Wine) and the licenses of the libraries it bundles |
| Graphics and support libraries (MoltenVK, FreeType, GStreamer, SDL and others) | [Sikarugir-App/Template](https://github.com/Sikarugir-App/Template) | Apache-2.0 (MoltenVK), LGPL (GStreamer) and others, each under its own terms |
| Steam client | Valve's official installer | Steam Subscriber Agreement |
| Cossacks 3 | Downloaded by Steam from the user's own library | Proprietary, © GSC Game World |

Steppe verifies the engine and library archives against pinned SHA-256 checksums before using them and applies four
documented byte-level fixes to Wine's macOS graphics driver (see `docs/ENGINE_PATCHES.md`).

## Trademarks

Cossacks is a trademark of its owners. Steppe is an independent community project and is not affiliated with, endorsed
by or sponsored by GSC Game World, Valve Corporation, Apple Inc. or the Wine project.
