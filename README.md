# Mimesis

Compare two sports videos (tennis, soccer, swimming…) side by side or overlaid, on macOS, iPadOS and iOS.

See [ROADMAP.md](ROADMAP.md) for the plan and what's done.

## Building

```bash
xcodegen generate
open Mimesis.xcodeproj
```

Schemes: `MimesisMac` (macOS 15) and `MimesisiOS` (iPhone and iPad, iOS 18). Shared code lives in
`Packages/MimesisKit`; video pieces come from [AreteMedia](https://github.com/jiapoo/apple-media), pinned in `project.yml`.
