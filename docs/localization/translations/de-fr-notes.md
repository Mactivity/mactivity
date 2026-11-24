# German and French translation notes

`de.json` and `fr.json` cover all 929 keys and pass `scripts/translations.py validate` with 0 problems.
The two languages follow Apple's conventions. German uses "du", a space before "…" in menu items
("Beenden …") and „…“ quotes. French uses "vous", no space before "…", « … » quotes, and a no-break
space (U+00A0) before : ; ? ! » and %. Terms in `glossary.json` are used as given. Everything below
needs a check by a native speaker.

## Terms without a glossary entry (choice made)

| English | de | fr | Confidence / note |
|---|---|---|---|
| Energy Impact | Energiebedarf | Impact énergétique | fr sure; de believed to be Activity Monitor's column name, verify |
| Memory Pressure | Speicherdruck | Pression de la mémoire | fairly sure both match Activity Monitor |
| Wired | Reserviert | Résidente | Activity Monitor: "Reservierter Speicher" / "Mémoire résidente" |
| Compressed | Komprimiert | Compressée | |
| App memory | App-Speicher | Mémoire de l’app | |
| Cached files | Dateien im Cache | Fichiers en cache | |
| Swap used | Belegter Swap | Swap utilisé | Activity Monitor's German may differ ("Benutzter Swap-Speicher"?) |
| Purgeable | Entfernbar | Purgeable | Finder wording as I recall it |
| Load average | Durchschnittliche Auslastung | Charge moyenne | |
| CPU Idle / User / System | Inaktiv / Benutzer / System | Inactif / Utilisateur / Système | Activity Monitor CPU tab |
| dev server | Dev-Server | serveur de dev | fr "serveur de développement" is too long for headers; "dev" is common jargon |
| daemon / launch agent | Daemon / Agent (Launch-Agents) | démon / agent | fr "démon" follows Apple's French developer docs |
| privileged helper / the helper | privilegiertes Hilfsprogramm / Hilfsprogramm | assistant privilégié / assistant | |
| Runtime (Node, Python…) | Runtime | Runtime | "Laufzeit" would read as a duration; fr has no short standard term |
| Alerts | Warnungen | Alertes | de "Mitteilungen" is used for notifications themselves |
| Storage (tab) | Speicherplatz | Stockage | de "Speicher" is already Memory; "Speicherkarte" would mean an SD card, hence "Speicherplatzkarte" for Storage map |
| Figure / Figures | Wert / Werte | Valeur / Valeurs | |
| Overview cards | Kacheln | cartes | de avoids clashing with "Karte" (the sunburst map) |
| Share card | Karte zum Teilen | carte de partage | |
| Startup (tab) | Systemstart | Démarrage | |
| Startup disk | Startvolume | disque de démarrage | |
| Home folder | Benutzerordner | dossier de départ | |
| Get Info / Inspector | Informationen | Lire les informations / inspecteur | |
| Login Items & Extensions | Anmeldeobjekte & Erweiterungen | Ouverture et extensions | glossary gives Login Items = "Ouverture" |
| Stop (dev server, container) | Stoppen | Arrêter | kept separate from Quit = Beenden / Quitter |
| Quiet hours | Ruhezeiten | Plages de silence | |
| Thermal states nominal / fair / serious / critical | Normal / Mittel / Hoch / Kritisch | Nominal / Moyen / Grave / Critique | |
| TCP "Time wait" | Abschluss-Wartezeit | Attente temporisée | no standard translation; consider keeping TIME_WAIT |
| Duration abbreviations d/h/m/s | T / h / min / s | j / h / min / s | de "T" for Tage is a guess; "d" is also seen |

## Menu bar labels

- MEM: de `RAM`, fr `MÉM`. NET: `NETZ` / `RÉS`. TMP: `TEMP` in both. BAT: `BAT` in both. German
  macOS says "Batterie", so `BAT` fits better than `AKKU`.
- **The UI catalog's `CPU` key is shared.** It is both the sidebar/tab title (`MainWindow.swift:42`)
  and the menu bar label next to MEM/NET (`Preferences.swift:131`). French Activity Monitor says
  "Processeur", which is too long for the menu bar, so this key stays `CPU` in French. The CPU
  keys in other catalogs (Core metric name, App Intents, Readouts, Export, Widgets) use
  "Processeur". Suggestion: give the menu bar its own key, e.g. comment "Menu bar abbreviation of
  CPU", so the tab can say "Processeur".

## Other deliberate choices

- `Xcode → Settings → Components` stays in English: Xcode is not localized.
- French prose writes "plusieurs Go" (Apple's French unit) where English says "several GB".
  Formatted values come from the formatters and are unaffected.
- Keys with no plural variation that start with a count (`%lld idle`, `%lld running`,
  `%lld stopped`, `%lld other`, `%lld broken`, `%lld unusual`) use forms that don't change with the
  count in French (au repos, en cours, à l’arrêt, divers, défectueux, hors norme).
- "Hourly at :%@" and similar: French says "à la minute %@", because "à :05" doesn't read as French.
  German keeps "um :%@".

## Ambiguous English strings

- `Memory pressure is warning.` (Readouts): ungrammatical English, translated as "elevated". Maybe
  change the English to "Memory pressure is elevated."
- `%lld idle`, `%lld running`, `%lld stopped`, `%lld other`, `%lld broken`, `%lld unusual`,
  `%lld from apps you have`, `%lld more in the Volume tab`, `Plus %lld from macOS, not listed.`,
  `and %lld more`: counts with no plural variants. French and German want them (e.g. "inactif" /
  "inactifs"). Add one/other variants.
- `Off` (UI): one key for a stopped fan, a disabled startup item and the helper being off. French
  needs different words (Arrêt / Désactivé), so it is "Désactivé", which reads oddly for a fan. Split it.
- `On` (UI): the helper state and an alert-rule toggle. Fine in both languages today.
- `Free` (UI): a disk figure, a legend entry and a memory type in one key. Gender differs in French
  (libre is invariable, so it's fine), but splitting would be safer.
- `None` (UI): "no interface" and "no muted apps". French "Aucune" fits both only by luck.
- `%1$@ of %2$@` (UI): both "12% of Library" (a share) and "used of total" (memory). French would
  prefer "de" for the first and "sur" for the second; "sur" was used.
- `Status` vs `State`: both are "Status" in German; French uses Statut / État.
- `It tells you` (UI): unclear without context (probably a feature line in onboarding).
  Translated as "Es sagt dir Bescheid" / "Il vous prévient".
- `View`, `Tab`, `Show`, `Share`, `Power` (widget): single words with unclear context.
  `Power` was translated as the power source ("Strom" / "Alimentation"). If it means power draw,
  use "Leistung" / "Consommation".
- `down · %@ up` vs `download · %@ up`: two nearly identical captions. German renders both as
  "Download · %@ Upload".
- `%1$@ and %2$@ is free.` / `are free.`: the second argument is a port phrase, so agreement
  depends on the port count. German and French use a form that works for both.
- `The container stops… Connections to %@ drop`: `%@` is a port phrase ("port 5432" or
  "ports 80 and 443"), so French can't put a preposition in front of it. It is in parentheses.
- `Up` / `Up %@` / `up %@`: uptime of the system vs. a process, and "Up %@ in…" meaning "grew by"
  in alerts. The same word has three meanings; the comments help but the keys collide easily.

## French terms added with the habits, developer tools, disk and Wi-Fi strings (2026-11-04)

drive = disque; network share = partage; macOS's log = journal de macOS; SSH forward = redirection;
Photos library = photothèque; Device Management = Gestion de l’appareil (read from macOS 27);
crowded channel = canal encombré; heard (Wi-Fi) = capté; like for like = à conditions égales;
power rating = puissance nominale; focus streak = série de concentration; leftovers = fichiers restants.

## German: terms added with the 1.x habits, developer tools and disk strings

Macs and drives: drive = Laufwerk, network drive = Netzlaufwerk, share = Freigabe, mounted = aktiviert (Disk Utility's word), Photos library = Fotos-Mediathek, charger = Netzteil, power rating = Nennleistung, unlocks = Entsperrungen, macOS's log = macOS-Protokoll, SSH forward = Weiterleitung, far side = Gegenseite, test run = Testlauf, focus streak = Fokusphase, leftovers = Überreste, busiest hours = Stoßzeiten. "Heard" and "sounds quieter" for Wi-Fi become "empfangen" and "wirkt ruhiger". "Like for like" is "unter gleichen Bedingungen", "matching charging" is "vergleichbares Laden". The battery metric "In use" is "Im Betrieb".
