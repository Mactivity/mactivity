# Spanish (es) and Italian (it): translator notes

Both files validate at 929/929 keys, 0 problems. They have not been imported yet. Everything listed here should get a native review.

## Terms with no Apple glossary entry

| English | es | it | Confidence |
|---|---|---|---|
| Energy Impact | Impacto energético | Impatto energetico | High (Activity Monitor) |
| Memory Pressure | Presión de memoria | Pressione memoria | High (Activity Monitor) |
| App memory | Memoria de apps | Memoria app | Medium. es Activity Monitor may say "Memoria de la app" |
| Wired | Residente | Wired | Medium. es follows Activity Monitor's "Memoria residente". it keeps the English word, as Activity Monitor appears to |
| Compressed | Comprimida | Compressa | High |
| Cached files | Archivos en caché | File in cache | High |
| Swap used | Swap utilizado | Swap utilizzato | Medium |
| Purgeable | Purgable | Eliminabile | Medium (Finder/Storage wording) |
| Load average | Carga media | Carico medio | Medium (standard technical term) |
| Threads | Subprocesos | Thread | Medium (Activity Monitor columns) |
| dev server | servidor de desarrollo | server di sviluppo | Standard term |
| daemon / agent | daemon / agente | daemon / agente | Standard launchd terms |
| privileged helper / the helper | auxiliar con privilegios / el auxiliar | helper con privilegi / l'helper | Low. No Apple term exists. es could use "herramienta auxiliar" instead |
| Login Items & Extensions (System Settings) | Ítems de inicio y extensiones | Elementi login ed estensioni | Medium. Built from the glossary term; check against macOS 27 |
| Home folder | carpeta de inicio | cartella Inizio | High (Finder) |
| Library folder | Biblioteca | Libreria | High (Finder's localized name). Key 478 keeps "Library", which reads as the literal folder name |
| Stop (dev server/container) | Detener | Arresta | Standard. it "Interrompi" is an alternative |
| Figure / Figures | Valor / Valores | Valore / Valori | Medium. No exact equivalent exists |
| Share card | tarjeta para compartir | scheda da condividere | Medium |
| Dashboard | panel | dashboard | Medium |
| Startup (tab) | Arranque | Avvio | Medium. es avoids "Inicio", which clashes with Home |
| Storage (tab) | Almacenamiento | Archiviazione | High |
| Quiet hours | Horas de silencio | Ore di silenzio | Medium |
| Build (Xcode/app build) | compilación | build | Standard usage |

Menu bar abbreviations: es MEM, RED, TEMP, BAT. it MEM, RETE, TEMP, BAT.

Short durations: es keeps d/h/m/s. it uses **g** (giorni) for days, so "%lldg", "30 g", "7 g", and keeps h/m/s.

## Ambiguous source strings and choices made

- **Count keys without plural variants.** These keys have no one/other variations in English, so Spanish and Italian adjectives cannot agree with 1. Where possible I used wording that works for any count: "%lld con errores", "%lld sin actividad", "%lld con ubicación inusual", "%lld en ejecución". Four keys still show "1 …" with a plural adjective: "%lld stopped" (es "detenidos", it "arrestati"), "%lld other" ("otros"/"altri"), "%lld idle" (it "senza attività" works; es is fine), and "Plus %lld from macOS, not listed." **Suggestion:** give "%lld stopped" and "%lld other" English one/other forms.
- **"Off"** (key shared by fan stopped, startup item disabled, and helper off): es "Desactivado", it "Disattivato". For a fan this reads a little oddly. The Core catalog's fan-only "Off" uses "Apagado" / "Spenta".
- **"Free"** (shared by disk %, the disk legend, and memory type): it "Libero" is masculine (spazio). Memoria would take "Libera". Splitting this key would allow proper agreement.
- **"None"** (network interface / muted apps): feminine "Ninguna" / "Nessuna" fits both of the current uses.
- **Toasts with a name as subject** ("%@ quit.", "%@ stopped.", "%@ restarted.", "%@ was force quit."): the gender of the name is unknown, so es uses "Se ha cerrado %@." and similar. it uses "Chiusura di %@ completata." / "Uscita forzata da %@ completata." for quit, but "%@ arrestato." / "%@ riavviato." (masculine, for containers and projects) for stop and restart.
- **Port phrases** (UI keys "port %@" / "ports %@"): these now include the article (es "el puerto %@", it "la porta %@") so they fit mid-sentence: "Libera 1 GB y el puerto 3000." The Readouts catalog's "port %@" stays without an article because it appears in spoken lists.
- **"Compare with the %@ before this"**: rendered as "Comparar con el periodo anterior (%@)" / "Confronta con il periodo precedente (%@)". This avoids gender and number agreement with "24 hours" and "7 days".
- **"Starts on"** (UI key 781): the context is unclear. It is rendered as "Se inicia" / "Si avvia". Please confirm what follows it.
- **"Power"** (widget): rendered as power source, "Alimentación" / "Alimentazione". If it means power draw, use "Consumo".
- **"It tells you"** (onboarding heading?): "Te avisa" / "Ti avvisa".
- **App Shortcut phrases**: these keep ${applicationName} and, like the English, carry no ¿? punctuation, since they are Siri phrases, not UI text.
- **Schedule strings**: "%1$@ a las %2$@" gives "a las 1:00" where Spanish grammar wants "a la 1:00". The same issue affects it "alle 1:00" ("all'1:00"). Weekly ("Semanalmente el %@") assumes the weekday name comes without an article.
- **"Yearly in %@ on day %lld"**: this was reordered to "el %2$lld de %1$@" / "il %2$lld %1$@".
- **Key 481** ("An app at 100% on the system default…"): the English has a single "%" rather than "%%", and the translations mirror it (followed by a space, so no placeholder is formed). Key 389 correctly uses "%%".
- **Xcode menu path** "Xcode → Settings → Components" is kept in English because Xcode is not localized.
- **"Messages"** in key 863 uses the localized app names "Mensajes" / "Messaggi". Mail and Safari are unchanged.

## Italian, added with the habits, drives and Wi-Fi strings (2026-11-04)

- **Around an hour:** "verso le ore %@" (the argument is a bare hour, "14"), so 1 o'clock needs no "l'una" form.
- **macOS's log:** "il log di macOS". **Charger:** "alimentatore". **SSH forward:** "inoltro". **Failed attempt/run:** "non riuscito/a".
- **Unlocks:** "sblocchi". **Device management:** "gestione dispositivi". **Heard (Wi-Fi):** "rilevata".

## Spanish terms added with the habits, developer tools, disk and Wi-Fi strings (2026-11-04)

drive = unidad; network share = recurso compartido; macOS's log = registro de macOS; SSH forward = reenvío;
Photos library = fototeca; Device Management = Gestión de dispositivos (read from macOS 27);
crowded channel = canal saturado; heard (Wi-Fi) = captada; like for like = en igualdad de condiciones;
power rating = potencia nominal; focus streak = racha de concentración; leftovers = archivos restantes.
"Around %@" is "hacia las %@", which reads wrong at 1 o'clock ("a la 1").
