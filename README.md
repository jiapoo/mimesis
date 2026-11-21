# Mimesis

Compare two sports videos (tennis, soccer, swimming…) side by side or overlaid, on macOS, iPadOS and iOS.

See [USER_GUIDE.md](USER_GUIDE.md) for how to use it, and [ROADMAP.md](ROADMAP.md) for the plan and what's done.

## Building

```bash
xcodegen generate
open Mimesis.xcodeproj
```

Schemes: `MimesisMac` (macOS 15) and `MimesisiOS` (iPhone and iPad, iOS 18). Shared code lives in
`Packages/MimesisKit`; video pieces come from [AreteMedia](https://github.com/jiapoo/apple-media), pinned in `project.yml`.

## Languages

English plus Simplified and Traditional Chinese, Japanese, Korean, Spanish, French, German, Brazilian
Portuguese, Italian and Russian, in `Localization/Localizable.xcstrings` (the app's text, MimesisKit's and
AreteMedia's) and `Localization/InfoPlist.xcstrings` (the camera prompt). Text shown to people is a
`LocalizedStringKey` (a literal in `Text`, `Button`, `.help`…) or `String(localized:)`, never a plain `String`.
After adding or changing text, run `Localization/tools/update.sh`: it adds new strings to the catalog,
says how many each language still needs, and lists English in the code that can't be translated as written.
