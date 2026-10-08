# Localization

GogglesView is available in English, Italian and French. The app follows the macOS language
(System Settings > General > Language & Region). Adding another language means adding one
folder of text; no code changes.

The Italian and French translations are machine-assisted. Corrections are welcome: open an
issue or a pull request that edits `it.lproj/Localizable.strings` or `fr.lproj/Localizable.strings`.

## How it works

The English text in the source code is the key. Translations are classic
`Localizable.strings` files:

```
Apps/GogglesView/BundleResources/Localization/
  en.lproj/Localizable.strings    generated, every key maps to itself
  it.lproj/Localizable.strings    Italian
  fr.lproj/Localizable.strings    French
```

`Apps/GogglesView/build-stub-bundle.sh` copies every `*.lproj` folder into
`GogglesView.app/Contents/Resources/` before signing, so the files are part of the sealed
bundle and end up in the DMG. `Info.plist` sets `CFBundleDevelopmentRegion` to `en` and lists
the shipped languages in `CFBundleLocalizations`.

Why `.strings` files and not a String Catalog (`.xcstrings`): the app is built with plain
`swift build` and assembled by a script, not by Xcode, so catalogs would not be compiled.
Plain `.strings` files need no tooling, work with SwiftUI and AppKit, diff well and can be
edited by anyone.

Two kinds of text:

* SwiftUI literals (`Text("Save")`, `Button("Save")`, `Toggle`, `Label`, `Picker`, `Section`,
  `TextField`, `Stepper`, `.help`, `.accessibilityLabel`, ...) are looked up in the main
  bundle by SwiftUI itself. No code change is needed.
* Everything else (AppKit alerts and menus, notification text, messages built in model code,
  strings held in variables, ternaries between two literals) goes through `L("English text")`
  from `Sources/GogglesView/Localization.swift`. `L("Bitrate: %lld Mbps", value)` formats with
  the translated string.

Rules for new code:

* Do not interpolate into a SwiftUI literal (`Text("Bitrate: \(x)")`). The key would depend on
  the type of `x`. Use `Text(L("Bitrate: %lld Mbps", x))`, or `Text(verbatim:)` for text that
  must not be translated (numbers, file names, product names).
* In a ternary, wrap each branch: `Text(on ? L("On") : L("Off"))`.
* Format keys use plain C specifiers: `%@` for strings, `%lld` for `Int`, `%.1f` for `Double`,
  `%%` for a literal percent sign. Pass `Int` (not `Int32`) for `%lld`.
* Use two keys for singular and plural (`"%lld clip"`, `"%lld clips"`), because languages
  differ in plural rules and a pasted `s` does not translate.
* Text that must stay English whatever the language (copied diagnostics and health reports)
  is built inside `Localization.english { ... }`, which makes `L` return the key.

## The check script

`scripts/localization.py` finds the keys in the sources and compares them with every
`<lang>.lproj`:

```
scripts/localization.py check      missing keys, extra keys, format specifier mismatches (exit 1 on problems)
scripts/localization.py stub       append missing keys to every non-English file, English text as placeholder
scripts/localization.py sync-en    regenerate en.lproj from the sources
scripts/localization.py new fr     create fr.lproj with every key stubbed
scripts/localization.py extract    print the keys and where they were found
```

`check` compares the number and kind of `%@`, `%lld`, `%.1f` ... specifiers between the key
and each translation. A translation may reorder arguments with positional specifiers
(`%2$@ ... %1$@`). The same checks run as unit tests (`LocalizationTests`).

Files that are developer tools stay English on purpose and are listed in `EXCLUDED_FILES` in
the script: the benchmark, the self-test, the session log viewer, the doc-shot renderer, the
Shortcuts intents and the web viewer page.

## Changing text in the app

1. Edit the English text in the Swift source.
2. `scripts/localization.py sync-en` then `scripts/localization.py stub`.
3. Translate the new `TODO` entries in each `<lang>.lproj/Localizable.strings` and delete the
   old entries that `check` reports as extra.
4. `scripts/localization.py check`.

## Adding a language

1. `scripts/localization.py new nl` creates `nl.lproj/Localizable.strings` with every key and
   the English text as placeholder.
2. Translate the values. Keep the keys, the `%` specifiers and the `\n` line breaks.
3. Add `nl` to `CFBundleLocalizations` in `Apps/GogglesView/BundleResources/Info.plist`.
4. `scripts/localization.py check` and `cd Apps/GogglesView && swift test --filter LocalizationTests`.
5. Build the bundle and look at the Settings tabs in that language (below).

The build script copies the new folder automatically.

## Trying a language

A bundled app picks the language from macOS. To force one for a single launch, pass
`-AppleLanguages "(it)"`:

```
Apps/GogglesView/build-stub-bundle.sh /tmp/gv-build     # scratch output, does not touch /Applications
GOGGLESVIEW_DEV_SHOTS=1 /tmp/gv-build/GogglesView.app/Contents/MacOS/GogglesView \
  --settings-shot General /tmp/general-it.png 900 -AppleLanguages "(it)"
GOGGLESVIEW_DEV_SHOTS=1 /tmp/gv-build/GogglesView.app/Contents/MacOS/GogglesView \
  --doc-shot clip-gallery /tmp/gallery-it.png -AppleLanguages "(it)"
```

The dev flags use an in-memory preferences domain, so your real settings are untouched. The
unbundled debug binary (`swift build --show-bin-path`) has no `Resources` folder and shows
English; use the assembled bundle.

## Translation notes (Italian)

* Plain and short, sentence case, same tone as the English. No em dashes.
* Kept in English: OBS, NDI, SRT, RTMP, UDP, LUT, keyframe, bitrate, frame rate, preset, look,
  replay, streaming, "goggles", and the names of the goggles' own menu entries ("Share
  Liveview", "OTG Wired Connection to Computer").
* "Background service" is "servizio in background", "recording" is "registrazione",
  "marker" is "marcatore", "clip gallery" is "galleria clip".
* Vocabulary follows `site/it/index.html` (Impostazioni, Generale, Avanzate, Portachiavi,
  Cestino, taglio, ricodifica).
* Not translated: log messages, the diagnostics report and connection health report text,
  file names, the `gogglesview://` URL scheme and its commands, the AppleScript dictionary
  (`GogglesView.sdef`), command line flags, Shortcuts action names, the web viewer page, and
  the developer tools (benchmark, self-test, session logs).

## Translation notes (French)

* Natural, concise UI French in the style of macOS: infinitive or imperative for buttons and
  menu items (Démarrer l'enregistrement, Ouvrir, Annuler), "vous" only where a sentence needs it.
* Kept in English: GogglesView, DJI, Goggles 3, OBS, NDI, SRT, RTMP, UDP, HLS, LUT, bitrate,
  codec, Mbps, fps, and the names of the goggles' own menu entries ("Share Liveview",
  "OTG Wired Connection to Computer").
* "Goggles" is "lunettes", "recording" is "enregistrement", "marker" is "marqueur", "clip
  gallery" is "galerie de clips", "race mode" is "mode course", "Trash" is "corbeille",
  "Keychain" is "trousseau", "System Settings" is "Réglages Système".
* Not translated: the same categories as for Italian (log messages, diagnostics and health
  report text, file names, URL scheme, AppleScript dictionary, Shortcuts action names, web
  viewer page, developer tools).
