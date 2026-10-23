# Bilibili NEXT icons

The editable masters are hand-authored, self-contained SVG files:

- [macOS](Bilibili-NEXT-macOS.svg): an inset rounded tile with transparent outer margins.
- [iOS / iPadOS](Bilibili-NEXT-iOS.svg): an opaque, full-bleed square; the system applies its icon mask.

Both use the same white television and next-video symbol on solid pink (`#F45183`).
There are no gradients, shadows, raster images, fonts or external resources.
The artwork is included under the repository's MIT license and does not imply official Bilibili endorsement.

## Regenerate application resources

On macOS, install `librsvg` if needed (`brew install librsvg`), then run:

```sh
Scripts/build-icons.sh
```

This updates `Assets/Bilibili-NEXT-icon.png`, `Scripts/AppIcon.icns`, and
`Apps/iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.
Each macOS icon size is rendered directly from the SVG. Generated resources are
checked in, so ordinary app builds do not require librsvg. Native app bundles
use ICNS / PNG resources; the SVG files remain the editable sources. The macOS
build installs the ICNS as `AppIcon-Flat.icns` to invalidate the earlier icon cache.

The earlier generated artwork is preserved in Git history.
