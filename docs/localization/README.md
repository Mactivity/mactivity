# Localization

Mactivity ships in English (the development language) and ten translations: German (`de`),
French (`fr`), Spanish (`es`), Italian (`it`), Brazilian Portuguese (`pt-BR`), Dutch (`nl`),
Japanese (`ja`), Korean (`ko`), Simplified Chinese (`zh-Hans`) and Traditional Chinese, Taiwan
vocabulary (`zh-Hant`). Every key in every catalog, including the `Info.plist` permission prompts,
has all ten. The translations were machine-drafted; `review.md` lists what a native speaker should
check first.

Every user-facing string goes through a String Catalog (`.xcstrings`). English is the development
language: the catalogs hold the English source text, and adding a language means filling in that
language's column in each catalog (Xcode's catalog editor, or `xcodebuild -importLocalizations`).
Shared terms Apple already translates (Activity Monitor, System Settings) are in `glossary.json`.

## Where the catalogs are

| Catalog | Covers |
|---|---|
| `App/Sources/Localizable.xcstrings` | the app target: menus, commands, App Intents, notifications |
| `App/InfoPlist.xcstrings` | `Info.plist`: display name, copyright, every `NS…UsageDescription` prompt |
| `Widgets/Sources/Localizable.xcstrings` | the widget extension |
| `Packages/MactivityKit/Sources/<Target>/Localizable.xcstrings` | each package target with user-facing text: Core, Alerts, Audio, Export, Projects, Readouts, Startup, Storage, UI |

A package target gets a catalog by `isLocalized: true` on its `Module` in `Package.swift`, plus a
`Localizable.xcstrings` and a `Strings.swift` (copy one from another target).

## Writing strings

**In the app and the widgets** (`Bundle.main`), SwiftUI literals are localized as they are:
`Text("Quit")`, `Button("Settings…")`. Strings built in Swift use `String(localized: "…")`.

**In the package**, a literal would be looked up in the app's catalog, not the target's. Always
pass the target's bundle, `.strings`:

```swift
Text("Memory pressure", bundle: .strings)
Text("\(count) processes", bundle: .strings)               // plural, see below
Button(String(localized: "Quit", bundle: .strings)) { … }  // any title parameter
Toggle(isOn: $on) { Text("Launch at login", bundle: .strings) }
.help(Text("Opens System Settings", bundle: .strings))
String(localized: "MEM", bundle: .strings, comment: "Menu bar abbreviation of Memory")
```

`Bundle.strings` is each target's own (`Sources/<Target>/Strings.swift`). Don't use
`Bundle.module` or `#bundle`: both trap when the resource bundle isn't beside the executable, and
the `mactivity` CLI in `Contents/Helpers` is exactly that case. `Bundle.strings` looks in the app's
`Contents/Resources` too, and falls back to English.

- **One key per sentence.** Interpolate the dynamic parts (`"Up \(growth) in \(span)"`) instead of
  gluing localized fragments, so a translator can reorder them.
- **Add a `comment:`** when the English is ambiguous out of context: abbreviations ("MEM"),
  single words ("Idle", "Full"), status tokens.
- **Don't localize data:** app and process names, paths, bundle IDs, unit symbols ("GB", "MB/s",
  "W", "°"), SF Symbol names, `UserDefaults` keys, `os.Logger` messages, fixtures. Use
  `Text(verbatim:)` for a literal that is data; `Text(someString)` never localizes.
- **Hot paths** (anything the menu bar redraws every tick): look fixed words up once, in a
  `static let`, not per sample. The menu bar's fixed widths (`MenuBarLayout.widestTexts`,
  `columnWidth`) measure the same localized strings it draws, so a longer translation widens the
  item instead of clipping it.

## Plurals

A count interpolated into a string (`"\(n) processes"`) becomes the key `%lld processes`. Give it
English `one`/`other` variations so "1 process" reads right:

```
scripts/strings.py plural UI "%lld processes" "%lld process"
```

(or Vary by Plural in Xcode's catalog editor). `make sync-strings` lists `%lld` keys without one.
A key with two counts needs one plural per argument (`scripts/strings.py plural-args`, see its
help); number every argument in its format (`%1$lld of %2$#@macs@ · checked %3$@`), since a mix of
numbered and unnumbered arguments reads the wrong one and crashes.

## Splitting a shared key

One English word can mean different things in different places ("Off" for a stopped fan, a
disabled startup item, the helper). A translator can only give a key one translation, so give each
meaning its own key with the English as the default value:

```swift
String(localized: "fan.off", defaultValue: "Off", bundle: .strings, comment: "Fan speed: the fans are stopped")
```

The catalogs use this for `fan.off`, `helper.status.off`/`.on`, `startup.status.off`,
`memory.free`, `network.interface.none`, `alerts.mutedApps.none`, `menubar.cpu`/`.gpu` (the menu
bar's short labels, so the CPU tab can be "Processeur" in French) and `storage.shareOfFolder`.

## Keeping the catalogs in sync

The compiler extracts every localizable literal during `make build` (`SWIFT_EMIT_LOC_STRINGS`).
`make sync-strings` builds, then merges those extracted keys into the source catalogs with
`xcstringstool sync`: new keys are added, keys no longer in the code are marked stale, and
translations are kept. Run it after adding or changing strings and commit the catalogs.
`InfoPlist.xcstrings` is synced from `App/Info.plist` by the same script.

## Translations

The translations live as plain JSON, one file per language, in `translations/<lang>.json` (catalog
path → key → text, or `{"one": …, "other": …}` for plurals, or `{"format": …, "substitutions": …}`
for keys with several counts). `translations/*-notes.md` record the translators' conventions and
choices per language; `glossary.json` has Apple's own words for shared terms. The JSON files are
the source of truth: `import` overwrites that language in the catalogs.

**Plural categories:** de, fr, es, it, pt-BR and nl give `one` and `other`; ja, ko, zh-Hans and
zh-Hant give `other` only. French `one` also covers 0.

**Placeholders** must match the English. A translation may move them, but then every placeholder
in it needs a position number (`%2$lld箇所に%1$@`): an unnumbered reorder reads each argument as the
wrong type and crashes. `validate` rejects it.

### After changing English strings (the delta)

1. `make sync-strings` (build, merge the extracted keys into the catalogs; add English plurals for
   any count key it lists), then `python3 scripts/translations.py export` to rewrite `source.json`.
2. `python3 scripts/translations.py delta <lang>` for each language. It compares `source.json` with
   the language file and with the `source.json` of the last commit that touched that file, and
   lists:
   - **new** keys the file doesn't have (a split key starts from the old shared key's translation);
   - **changed** keys whose English text or plural forms moved on while the translation stayed the
     same (`--since <rev>` picks another baseline);
   - **obsolete** keys gone from the catalogs; `--prune` removes them from the file.

   It prints the new and changed keys as JSON (English, comment, current translation) to hand to a
   translator.
3. Put the translations in `translations/<lang>.json`, then for every language
   `python3 scripts/translations.py validate <lang> docs/localization/translations/<lang>.json`
   (0 problems and a full key count) and `… import <lang> …`.
4. `python3 scripts/translations.py status` shows every catalog with all ten languages at its full
   count. Then `make build`, `make lint`, `make test` (the "Shipped translations" suite loads each
   language's compiled strings: key strings translated, menu bar labels no wider than their
   column's values, every plural resolves for 1 and 5) and `make test-pseudo`.
5. Add anything a native speaker should check to `review.md`, and commit the catalogs, `source.json`
   and the translation files together, so the next `delta` has the right baseline.

To fix one translation, edit it in `translations/<lang>.json`, then validate and import that
language. Editing the catalog in Xcode works too, but the next `import` overwrites it.

## Checks

- `make check-strings` (part of `make lint`) fails on a SwiftUI literal in the package with no
  bundle: `Text("…")`, `Button("…")`, `Label("…"`, `Toggle("…"`, `Picker("…"`, `Section("…")`,
  `.help("…")` and the like. `Text(verbatim:)` and calls with `bundle:` pass.
- `make run-pseudo` launches the Debug app with `-NSDoubleLocalizedStrings YES`: every localized
  string appears twice, about as long as German or Finnish, to spot clipping and overflow.
- `make run-lang L=de` launches it in another language.
- `make test-pseudo` runs the window-fit, menu bar window, and menu bar width tests with doubled
  strings.
