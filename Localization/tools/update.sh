#!/bin/bash
# Refreshes Localization/Localizable.xcstrings from the code, and lists text that can't be translated.
#   Localization/tools/update.sh
# 1. Builds the Mac and iOS apps with the compiler listing every translatable string (.stringsdata).
# 2. Adds new strings to the catalog (Xcode's own sync only sees the app targets, not MimesisKit or
#    AreteMedia, so it's done here; the catalog's entries are "manual" so Xcode leaves them alone).
# 3. Prints English text in the code that isn't translatable as written (a String, not a
#    LocalizedStringKey or String(localized:)), and how many strings each language still lacks.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/mimesis-loc"
rm -rf "$OUT"
xcodebuild -project Mimesis.xcodeproj -scheme MimesisMac -derivedDataPath "$OUT" build SWIFT_EMIT_LOC_STRINGS=YES -quiet
xcodebuild -project Mimesis.xcodeproj -scheme MimesisiOS -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$OUT" build SWIFT_EMIT_LOC_STRINGS=YES -quiet
# The debug-only masking test and AreteMedia's viewer (unused here) stay out.
files=$(find "$OUT" -name "*.stringsdata" | grep -v "MaskLabView\|MaskProbe\|/MediaViewer\.\|/ZoomableImage\.\|ExtractedAppShortcuts")
xcrun xcstringstool sync Localization/Localizable.xcstrings --stringsdata $files
python3 - <<'PY'
import json
p = 'Localization/Localizable.xcstrings'
d = json.load(open(p))
langs = ['zh-Hans', 'zh-Hant', 'ja', 'ko', 'es', 'fr', 'de', 'pt-BR', 'it', 'ru']
for v in d['strings'].values():
    v['extractionState'] = 'manual'
json.dump(d, open(p, 'w'), ensure_ascii=False, indent=2, sort_keys=True)
open(p, 'a').write('\n')
todo = {l: [k for k, v in d['strings'].items() if v.get('shouldTranslate', True) and l not in v.get('localizations', {})] for l in langs}
for l, keys in todo.items():
    print(f"{l}: {len(keys)} to translate" + (f" — {keys[:5]}" if keys else ""))
PY
echo "Text that can't be translated as written:"
python3 Localization/tools/coverage.py "$OUT" Packages/MimesisKit/Sources/MimesisKit/*.swift Mac/*.swift iOS/*.swift ShareExtension/*.swift \
    | grep -v "MaskLabView\|MaskProbe\|Helvetica\|'Application'\|'Left'\|'Right'\|'Mimesis Pro'" || echo "  none"
