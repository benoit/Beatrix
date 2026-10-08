# Beatrix app icons

The blonde silver Beatrix design is included in the app target.

- `Beatrix/AppIcon.icon`: native Icon Composer document with a transparent foreground, purple default background (#7E39C5), black dark background (#000000), glass effects and automatic Mono appearance. Clear/tinted backgrounds are controlled by the system.
- `Beatrix/Assets.xcassets/AppIcon.appiconset`: light/dark/grayscale tinted legacy assets. Xcode generates device sizes.

Both are named AppIcon. The native document is included in Copy Bundle Resources. Xcode GUI builds have been confirmed; the automation environment's command-line native icon exporter cannot open the document.

`Design/IconPreviews/clear.png` is a flattened design concept, not the native clear rendering. `Design/IconLayers/Beatrix.png` is the transparent source foreground prepared with the built-in image generator. Material and appearance settings were created in Apple Icon Composer.
