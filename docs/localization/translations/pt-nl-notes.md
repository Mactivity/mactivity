# pt-BR and nl translation notes

These notes cover `pt-BR.json` and `nl.json`, 929 keys each. Both files validate with 0 problems. The terms below need a native speaker to check before release.

## Apple terms used (glossary or Activity Monitor)

| English | pt-BR | nl | Confidence |
|---|---|---|---|
| Quit / Force Quit | Encerrar / Forçar Encerrar | Stop / Forceer stop | glossary |
| Login Items | Itens de Início | Inloggen | glossary |
| Energy Impact | Impacto de Energia | Energie-impact | fairly sure (Activity Monitor) |
| Memory Pressure | Pressão da Memória | Geheugendruk | fairly sure (Activity Monitor) |
| App memory / Cached files / Swap used | Memória de apps / Arquivos em cache / Swap usado | Appgeheugen / Bestanden in cache / Swap gebruikt | fairly sure |
| Wired | Fixa | Vast | **unsure**: check Activity Monitor's Memory tab on a pt-BR/nl Mac |
| Compressed | Comprimida | Gecomprimeerd | fairly sure |
| Purgeable | Purgável | Opschoonbaar | **unsure**: Finder/About This Mac may use a different word |
| Load average | Carga média | Gemiddelde belasting | standard technical term |
| Idle (CPU figure) | Inativo | Inactief | Activity Monitor CPU tab |
| Battery health / Cycle count | Saúde da bateria / Contagem de ciclos | Batterijconditie / Aantal cycli | fairly sure |
| Keychain | "nas Chaves" | sleutelhanger | **unsure (pt-BR)**: macOS pt-BR may say "Chaves" or "Acesso às Chaves" |
| Home folder | pasta de início / Pasta de Início | thuismap | pt-BR **unsure** ("pasta pessoal" is the other candidate) |
| Applications / Library (folders) | Aplicativos / Biblioteca | Programma's / Bibliotheek | nl **unsure**: newer macOS may show "Apps" |
| Login Items & Extensions (System Settings path) | Itens de Início e Extensões | Inloggen en extensies | **unsure**: check the exact pane name in macOS 26/27 |
| Full Disk Access | Acesso Total ao Disco | Volledige schijftoegang | fairly sure |
| Menu Bar (System Settings) | Barra de Menus | Menubalk | fairly sure |
| Activity Monitor | Monitor de Atividade | Activiteitenweergave | sure |
| Messages (app) | Mensagens | Berichten | sure |

## Terms with no Apple translation (chosen, please review)

- **dev server**: pt-BR "servidor dev" / "servidores dev". This is short and developers use it, but "servidor de desenvolvimento" is the formal term if you want it. nl "devserver" / "devservers". "ontwikkelserver" is the formal alternative.
- **daemon / agent / launch agent**: pt-BR "daemon", "agente". nl "daemon", "agent", "launch agents". The `LaunchAgents` folder name is left as it is.
- **privileged helper**: pt-BR "auxiliar privilegiado". nl "bevoegde helper". Plain "Helper" is "Auxiliar" / "Helper".
- **helper process**: pt-BR "processo auxiliar". nl "hulpproces".
- **Alerts** (feature, tab): pt-BR "Alertas". nl "Waarschuwingen". I avoided "Meldingen" because that is the word for macOS Notifications.
- **Figure** (a metric's displayed value; menu bar mode, the Settings "Figures" section): pt-BR "Valor" / "Valores". nl "Waarde" / "Waarden".
- **Metric**: pt-BR "Métrica". nl "Meetwaarde".
- **Share card**: pt-BR "cartão de compartilhamento". nl "deelkaart".
- **Dashboard** (image): pt-BR "painel". nl "dashboard".
- **Scan** (storage): pt-BR "Analisar" / "análise". nl "Scan" / "scannen".
- **Runtime** (column for Node, Python and so on, plus simulator runtimes): left as "Runtime" in both languages.
- **Uptime / "Up"** column: pt-BR "Tempo ativo" / "Ativo há %@". nl "Looptijd".
- **Quiet hours**: pt-BR "Horário de silêncio". nl "Stille uren".
- **TCP states**: pt-BR uses feminine forms (they agree with "conexão"): Aceitando, Aguardando fechamento, Fechada, Fechando, Conectando, Estabelecida, Escutando, Aguardando expiração (TIME_WAIT). nl uses Accepteert, Wacht op sluiten, Gesloten, Wordt gesloten, Maakt verbinding, Tot stand gebracht, Luistert, Wacht op time-out. The TIME_WAIT and CLOSE_WAIT wording is loose.
- **Docker states**: "Dead" is "Morto" / "Dood". This is literal; review it.
- **Durations**: pt-BR uses d, h, **min**, s ("2h 5min"). nl uses d, **u**, m, s ("2u 5m"). History ranges: "12 h" / "12 u".
- **Menu bar abbreviations**: pt-BR MEM, REDE, TEMP, BAT. nl GEH, NET, TEMP, BAT.
- **Build** (signed build, debug builds): translated as "versão" / "versie". Xcode build products are "compilação" / "build".

## Grammar choices to know about

- **Plural forms on keys where the English has none.** English "%lld idle", "%lld other" and "%lld stopped" are plain strings. In pt-BR the adjective agrees with the count, so these three keys are given `one`/`other` forms there (`%lld ocioso/ociosos`, `%lld outro/outros`, `%lld parado/parados`). nl keeps plain strings. The validator accepts this, and `import` writes them as plural variations. If you would rather keep the English shape, reword them as invariant phrases.
- Other count segments use wording that doesn't change with the count: pt-BR "%lld em execução", "%lld com defeito", "%lld em local incomum"; nl "%lld actief", "%lld defect", "%lld ongebruikelijk".
- The pt-BR "Weekly on %@" is "Semanalmente: %@". This avoids gender agreement with the weekday name (segunda-feira is feminine, sábado and domingo are masculine).
- The pt-BR "Yearly in %1$@ on day %2$lld" is reordered to "Anualmente no dia %2$lld de %1$@".
- pt-BR uses the article with the app name, as Apple does ("O Mactivity…", "Sobre o Mactivity"), except in "Encerrar Mactivity".
- Dutch commands use Apple's imperative style ("Kopieer pad", "Toon in Finder", "Annuleer", "Gereed"). Confirmation titles use the infinitive ("%@ stoppen?").
- In Dutch, Quit and Stop (dev server or container) are both "Stop". pt-BR keeps them apart: "Encerrar" and "Parar".

## Ambiguous source strings

- **"Up %@ in %lld minutes, now %@." and similar**: the English key has unnumbered `%@ … %lld … %@`. The translations keep the same order, so nothing is reordered there.
- **"%@ and %@ is free." vs "are free."**: in both languages the two keys have the same translation ("estão livres" / "zijn vrij"). With two subjects, the plural verb is correct either way.
- **"down · %@ up" and "download · %@ up"**: both become "download · %@ upload" in both languages. There is no natural short Portuguese or Dutch pair for "down/up".
- **"%@ cores (%lld)"**: this assumes the cluster name is already localized. It becomes "Núcleos de Desempenho (6)" and "Prestatie-cores (6)". If the name stays in English ("Performance"), the Dutch hyphenated form will look odd.
- **"Off"** (one key for a stopped fan, a disabled startup item and the helper being off): pt-BR "Desativado". This fits the last two, but for the fan "Desligado" would be better. Splitting the key would fix it.
- **"Critical" / "Elevated"**: pt-BR uses the feminine forms "Crítica" and "Elevada", on the assumption that they describe a pressure ("pressão").
- **"Compare with the %@ before this"**: pt-BR is "Comparar com o período de %@ anterior", which avoids gender agreement with "horas" or "dias".
- **"App Shortcuts" phrases**: `${applicationName}`, `${limit}` and `${metric}` are kept. Siri phrase quality in pt-BR and nl should be tested by speaking them.
- **"So "why was my Mac slow at 2 pm" has an answer."**: the inner quote is rendered with typographic quotes (“…” in pt-BR, ‘…’ in nl), so no escaped `"` is needed.
- **Xcode menu path "Xcode → Settings → Components"**: left in English, because Xcode is not localized.

## pt-BR, added with the habits, drives and Wi-Fi strings (2026-11-04)

- **Around an hour:** "por volta de %@" with no article (the argument is "14h"), so "1h" needs no "da".
- **Drive:** "unidade". **Photos library:** "fototeca". **Scan (Wi-Fi):** "análise" / "Analisar", the same as Storage. **SSH forward:** "encaminhamento".
- **Writing to disk:** "gravar". **Failed attempt:** "tentativa falha". **Heard (Wi-Fi):** "detectada". **Device management:** "gerenciamento de dispositivos".

## Dutch: terms added with the 1.x habits, developer tools and disk strings

Drive = schijf, network drive = netwerkschijf, share = share, mounted = geactiveerd (Schijfhulpprogramma's word), Photos library = fotobibliotheek, charger = lader, power rating = vermogen, unlocks = ontgrendelingen, macOS's log = macOS-logboek, SSH forward = doorsturing (**unsure**), far side = andere kant, test run = testrun, focus streak = focusreeks, leftovers = restanten, busiest hours = drukste uren, device management = apparaatbeheer. "Heard" for Wi-Fi is "opgevangen". "Like for like" is "onder gelijke omstandigheden", "matching charging" is "vergelijkbaar opladen".
