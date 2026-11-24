# Native review list

Every translation was machine-drafted. This is what a native speaker should check first, merged
from the translator notes (`translations/*-notes.md`, which have the full reasoning) plus the
strings added on 2026-09-27. Check each item in the running app (`make run-lang L=xx`) where you
can, since context decides most of them. Tick an item off by deleting it once it's confirmed or
fixed in `translations/<lang>.json` (then validate and import, see README).

## All languages

- **Activity Monitor and System Settings terms without a glossary entry.** Compare with the real
  UI on a Mac set to that language: Energy Impact, Memory Pressure, Wired, Compressed, App memory,
  Cached files, Swap used, Purgeable, CPU Idle/User/System, Login Items & Extensions (the macOS
  26/27 pane name), Full Disk Access, Menu Bar pane, Home folder, Library, Keychain (pt-BR).
- **Coined terms:** dev server, daemon / launch agent, privileged helper, Runtime, Figure(s), share
  card, dashboard, Quiet hours, Startup tab, Storage map, thermal pressure levels, TCP states
  (TIME_WAIT, CLOSE_WAIT), Docker "Dead".
- **Core clusters (new):** "Super / Performance / Efficiency cores (%lld)". Apple's names for the
  clusters in each language may differ (de Leistungs-/Effizienzkerne, fr cœurs de performance /
  d'efficacité, ja 高性能/高効率コア, zh-Hans 性能/能效核心, zh-Hant 效能/節能核心). "Super" cores are new
  with M5-era chips; check Apple's own wording once it exists.
- **Sound tab (new, was Volume):** de Ton, fr Son, es Sonido, it Suono, pt-BR Som, nl Geluid,
  ja サウンド, ko 사운드, zh 声音/聲音, following the System Settings pane name.
- **"Started on demand by" (new, was "Starts on"):** label before launchd key names
  (MachServices, Sockets…), which stay in English.
- **"used by apps" (new):** caption under the apps' total power (watts) on a desktop Mac.
- **"Not sampled" (new):** the inspector's trail for a process Mactivity wasn't sampling.
- **Siri phrases (App Shortcuts):** say them aloud; `${applicationName}` must stay.
- **Figure explanations (new, 2026-09-28):** the hover text on Wired, Compressed, Cached files,
  Swap used, App memory, Pressure, Load average, the core clusters, Apps' power and Energy Impact.
  Plain, short sentences; check they stay plain. The Pressure one quotes the status word "Normal",
  which must match that language's memory status word.
- **Quick Look (new):** de Übersicht, fr Coup d’œil, es Vista rápida, it Visualizzazione rapida,
  pt-BR Visualização Rápida, nl Snelle weergave, ja クイックルック, ko 훑어보기, zh 快速查看; compare
  with Finder's menu. Terminal's name too (it Terminale, zh 终端 / 終端機).
- **"Mute Alerts for %@" / "Unmute Alerts for %@" (new):** in the app row's menu and as a
  notification button. ja/ko follow "Apps with muted alerts" (通知をオフ / 알림 끄기).
- **VoiceOver only (new):** "Latest %@, rising/falling/steady" (sparklines) and "Average %1$@,
  peak %2$@ at %3$@" (history charts; most languages put the time in parentheses, since it may be
  a date and a time).
- **Durations** (d/h/m/s abbreviations, `12 h`, `7 d`): de uses "T" for days, it "g", nl "u" for
  hours; ja/ko/zh spell them out and are wider.
- **Separator captions** "down · %@ up" and "download · %@ up": most languages render both the
  same way.

## German (de)

- Energiebedarf (Energy Impact) and "Belegter Swap" (Activity Monitor may say "Benutzter
  Swap-Speicher").
- Duration abbreviation "T" for days ("d" is also common).
- "Abschluss-Wartezeit" for TIME_WAIT; consider keeping TIME_WAIT.
- Menu bar labels RAM, NETZ, TEMP, BAT.

## French (fr)

- "serveur de dev", "démon", "assistant" (helper), "Purgeable", "Ouverture et extensions".
- "à la minute %@" for "Hourly at :%@".
- The CPU tab is now "Processeur"; the menu bar label stays "CPU". Menu bar: MÉM, RÉS, TEMP, BAT.
- "%@ and %@ is/are free." with a port phrase: a form that works for one and several ports.

## Spanish (es) and Italian (it)

- Helper: es "auxiliar con privilegios" (or "herramienta auxiliar"), it "helper".
- es "Arranque" for the Startup tab; "Purgable"; it "Wired" left in English.
- Toasts with a name as subject avoid gender ("Se ha cerrado %@."); it uses masculine "%@
  arrestato/riavviato" for containers and projects.
- Schedules: "a las 1:00" should be "a la 1:00" (es), "alle 1:00" should be "all'1:00" (it).
- es/it "Off" for a stopped fan: "Apagado" / "Spenta" (it "Spenta" agrees with ventola; check
  with the plural "Fans" label).
- it "%lld altra app / Altre %lld app nella scheda Suono" (new plural).

## Portuguese, Brazil (pt-BR)

- "Fixa" (Wired) and "Purgável" are unsure; "pasta de início" vs "pasta pessoal"; "nas Chaves".
- "servidor dev" vs "servidor de desenvolvimento".
- Feminine TCP states (agree with "conexão"); "Crítica"/"Elevada" assume "pressão".
- "Semanalmente: %@" avoids weekday gender.

## Dutch (nl)

- "Vast" (Wired), "Opschoonbaar" (Purgeable), "Programma's"/"Bibliotheek" vs newer "Apps".
- Quit and Stop (dev server) are both "Stop".
- "devserver", "bevoegde helper", "Waarschuwingen" for Alerts (Meldingen = Notifications).
- Menu bar label GEH for Memory.

## Japanese (ja) and Korean (ko)

- Activity Monitor words from memory: ja 確保されているメモリ (Wired), ko 와이어드 메모리, ko 대기 (CPU
  Idle), ko 압축됨.
- Coined: 通知停止時間帯 / 알림 끔 시간 (Quiet hours), 起動項目 / 시동 항목 (Startup tab), 熱負荷 / 열 부하.
- Docker states; "Dead" (異常停止 / 비정상 중지) may read better left in English.
- Menu bar labels stay Latin (MEM, NET, TMP, BAT); native 温度/電池, 온도 are options.
- "%@ of developer data in %lld places" now uses numbered placeholders (the old unnumbered
  reorder crashed); check the reading.
- Alert rule picker labels 超過 / 書き込み超過 / 増加量 / 継続時間 (ko 초과 / 쓰기 초과 / 증가량 / 지속 시간).
- ko "켜짐" is now used for the helper's On status (the alert-rule toggle keeps "켬").

## Chinese (zh-Hans, zh-Hant)

- zh-Hans uses 访达 for Finder (Apple's zh_CN name); zh-Hant keeps "Finder".
- 登录项与扩展 / 登入項目與延伸功能 and 菜单栏 / 選單列 as System Settings pane names.
- zh-Hant Energy Impact 能耗影響 (Activity Monitor may say 能源影響); daemon 常駐程式 (or 守護程式,
  背景程式); menu bar keeps MEM for Memory (記憶體 or RAM are options).
- Wired 联动内存 / 固定記憶體; Compressed / Cached / Swap wording.
- Counters with 个/個 in summary segments ("%lld 个闲置").
- "no ports" mid-sentence reads awkwardly (将释放 1 GB 和 无端口).

## Resolved in the English source (2026-09-27)

No review needed; listed so the notes files' questions have an answer.

- Count keys now have plurals: "%lld idle/running/stopped/other", "%lld broken/unusual",
  "%lld from apps you have", "Plus %lld from macOS, not listed.", "%lld more in the Sound tab",
  "and %lld more", "All %lld Macs are in use…".
- Split keys: "Off" (fan / startup item / helper), "On" (helper vs alert rule), "Free" (disk vs
  memory), "None" (interface vs muted apps), "CPU" (tab vs menu bar), "%1$@ of %2$@" (share of a
  folder vs used of total).
- "Memory pressure is warning." is now "Memory pressure is elevated."
- "Muted apps" is now "Apps with muted alerts".
- The inspector's footer for a process of macOS or another user says so.
- CPU cluster names are localized instead of showing the kernel's English word.
- Weekday and month names in schedules come from the calendar in the app's language.
- Widget "Power" is gone (the GPU figure replaced it); "On power" has a comment.

## 0.9.6: sleep, crashes, accessories, disk totals, Mac-level alerts

First translated 2026-09-28; these keys are worth a native speaker's look.

- **"Power Nap" (zh):** 电能小憩 (zh-Hans), 電能小睡 (zh-Hant), from memory of Apple's names. ja, ko and nl keep "Power Nap".
- **"Lid opened":** nl "Deksel geopend" (Apple may say "klep"); ja 蓋を開いた; zh 打开机盖 / 打開機蓋.
- **"Recent wakes" (nl):** "Recent gewekt". Check Apple's Dutch word for waking from sleep.
- **"Network access" as a wake reason (zh-Hant):** 網路取用, following the files' 取用 for "access".
- **"Full within" (a picker label before values like "1 week"):** the zh and ja labels read less naturally beside the value than the English does.
- **"Time in front" / "Record which app is in front":** ko 전면 (Apple may use 최전면 or 맨 앞); zh-Hant 前景 and 最前方.
- **Hang terms:** zh 无响应 / 無回應 and ko 멈춤, against Apple's "not responding" wording.
- **"%@ left. Charge it soon." (nl):** "het" assumes the accessory is neuter.
- **Alert rule summaries (ja, ko):** written as noun phrases; check them in the Alerts list.
- **"Sleep" as a section title:** de Ruhezustand, fr Veille, es Reposo, it Stop, pt-BR Repouso. Italian "Stop" is Apple's menu word but may look odd alone.
- **Hangs:** de "Hänger" (colloquial), fr "blocage", es "bloqueo", it "blocco", pt-BR "travamento".
- **"Recent wakes":** de "Letzte Weckvorgänge", fr "Réveils récents", es "Activaciones recientes", it "Riattivazioni recenti", pt-BR "Despertares recentes".
- **The "keeping awake" phrases** were reworded in fr, es, it and pt-BR to avoid agreeing a verb with an unknown list of apps; check they read naturally.
- **"An accessory" (de):** "Ein Gerät", as other German strings call accessories "Geräte"; the section is "Zubehör".
- **"Read" / "Written" (fr):** "Données lues" / "Données écrites", since the bare participles read poorly alone.

## 0.9.6, second batch: Checkup, Your week, battery use, uninstaller

- **"Checkup"**, a coined name: de Check-up, fr Bilan, es Revisión, it Controllo, pt-BR Revisão, nl Check-up, ja 点検, ko 점검, zh-Hans 体检, zh-Hant 健檢.
- **"Optimized Battery Charging"** from memory of Apple's names in each language (the Dutch is least certain). Check against System Settings → Battery.
- **"macOS may recommend service"**: de Service, fr réparation, es reparación, it assistenza, pt-BR manutenção, nl onderhoud, ja 修理サービス, ko 서비스, zh 维修 / 維修.
- **"Your startup disk fills up in about %@" (de)**: reworded as "Zeit, bis dein Startvolume voll ist: etwa %@", because the duration formatter gives the nominative.
- **"Keeping your Mac awake: %@"**: fr, es, it and pt-BR avoid agreeing a verb with the list of apps.
- **"Worth doing soon" / "Worth knowing"**, "Your week", "My Mac this week" and "Your Mac last week" in ja, ko and zh: check they read naturally.
- **"Health %@"**: ja 状態, zh 健康度, nl Conditie. **"Used %@, charged %@"** in zh: 用掉 / 充入.
- **"Your Mac slowed down to stay cool"**: Apple has no user-facing word for thermal throttling; each language renders it literally.
- **Uninstall kinds** ("Settings file", "Logs", "The app"), and **nl "Verwijder app…"**.
- **ko "Asleep a night"** (하룻밤 평균 잠자기) is a little awkward.

## 0.9.8 features (D-134 to D-137), machine-drafted 2026-10-11

Check first:
- **Low Data Mode** (hotspot card): de "Modus für geringe Datennutzung", fr "mode données réduites", es "modo de datos reducidos", it "Modalità dati ridotti", pt-BR "Modo Dados Reduzidos", nl "modus voor weinig data", ja 省データモード, ko 저데이터 모드, zh-Hans 低数据模式, zh-Hant 低數據模式. Use Apple's exact names from System Settings → Wi-Fi.
- **Personal Hotspot:** ja インターネット共有, ko 개인용 핫스팟, pt-BR "Acesso Pessoal", fr "partage de connexion"; es, it, nl and de say "hotspot" or "punto de acceso".
- **"The display server is busy"** (WindowServer): no Apple term; every language guessed.
- **Wi-Fi:** de "WLAN", nl "wifi", zh-Hans 无线局域网.
- **"Used since %@"** (es "desde las %@", it "dalle %@"): reads oddly at 1:00, the same issue as the schedule strings.

## 1.4 (D-223 to D-228)

- **"Left behind"** (dev tools whose editor quit) is "orphaned" in most languages: de "verwaist", fr "orphelin(s)", es "huérfana(s)", it "orfano/orfani", pt-BR "órfã(s)". Count keys without plural forms use a label style ("Orphelins : 2, 3,2 Go", "Noch aktiv: 2").
- **Projects → Space** is "Platzbedarf" in German, not "Speicherplatz", which is already the Storage page.
- **"Untouched"** (no work in two months): de "Unberührt", fr "Délaissés", es "Sin tocar", it "Fermi".
- **"dev tools"** in Dutch is "ontwikkeltools", as "devtools" reads as a browser's DevTools.
- **Projects → Dev Tools** is short in each language's toolbar: es "Desarrollo", it "Strumenti dev", fr "Outils de dev", de "Dev-Tools". The 17 strings added in D-229 were translated in one pass without a second reader.

## 1.5 (D-230 to D-235)

- **Wi-Fi** follows each language's Apple usage: de "WLAN", nl "Wifi", zh-Hans keeps "Wi-Fi" though older keys say 无线局域网, so the app is now mixed there.
- **Data budget words** have no Apple term: de "Datenbudget"/"Volumen", fr "budget de données"/"quota", es "presupuesto de datos"/"cuota", it "budget dati"/"quota", nl "Databudget"/"Bundel", pt-BR "Cota de dados"/"Franquia", ja "データ上限", ko "한도", zh-Hans "流量额度", zh-Hant "數據額度".
- **Apple's names from memory, to verify:** AirPlay Receiver (ko "AirPlay 수신 모드", zh-Hans 隔空播放接收器), stealth mode, Continuity (left in English in de/fr/es/it/ja), Personal Hotspot (es "Punto de acceso personal").
- **The new-startup-item alert** slots a phrase ("an agent that runs at login") into "It added %1$@ (%2$@)": French opens "Nouvel élément : …" for the unknown gender; check the phrases read naturally in each language.
- **"identified developers"** uses Gatekeeper's older wording; newer macOS may say "known developers".

## 1.5.1 (D-237, D-238)

- **Displays settings** use each language's System Settings name, from memory: de "Displays", fr "Moniteurs", es "Pantallas", it "Monitor", nl "Beeldschermen", pt-BR "Telas", ja/ko "ディスプレイ"/"디스플레이", zh 显示器/顯示器. German's button reads "Displays-Einstellungen …" with a space before the ellipsis; the rest of the app has none. Fix in the next pass.
- **"Looks like"** (the resolution setting) should match what Displays settings shows in each language; ja "%@相当" is shorter than Apple's wording.
- **"YOUR DESK"** is a desk you work at, not a desktop computer: ja "デスク環境", zh 办公桌/辦公桌.
- **"Mac mini drives three, Mac Studio does"** was written without a translator, from the MacBook Air sentence's pattern.

## 1.6 (D-245 to D-250)

- **German's ellipsis** is " …" with a space throughout (96 strings); the 1.5.1 note above had it backwards.
- **"Processor, busiest tenth"** (Compare two Macs) is literal in most languages; pt-BR says "10% mais ocupado". A "top 10%" wording may read better everywhere.
- **"Out of the ordinary" as an intent and Siri phrase** is new wording: de "Ungewöhnliches abrufen", fr "Obtenir ce qui sort de l’ordinaire", nl "Haal ongewoon gebruik op", pt-BR "Obter Fora do Comum". Say the Siri phrases aloud in each language.
- **"Hold alerts while I present or am on a call"**: nl "vasthouden" and pt-BR "Segurar" may want "uitstellen"/"Adiar".
- **"Slower: %1$@, %2$@ against %3$@."** is spoken by Siri; ja, ko and zh reword it as "from before to now".
- **Agents in Chinese:** the new Siri summaries use 智能体 / AI 代理 like the Agents page; the older "Agents worked …" readout says 代理.
- **"A quiet day…"** now says alerts with the Alerts tab's word (nl "waarschuwingen", ja アラート, zh 警报/警示); History's older sentence says 通知/提醒/meldingen.
- **Shortcut recorder keys:** de "Rückschritttaste", fr "Supprimer"/"Échap", es "tecla Borrar"; check against Apple's key names.

## 1.6.5 (D-252)

- **Severity words** fill "the worst %@"; most languages reword it as "highest severity: %@" with the words agreeing with that noun (fr/es/it/pt-BR feminine). zh-Hant uses 高風險/中風險/低風險; plain 高/中/低 may be preferred.
- **"Checked for known vulnerabilities %@"** takes a relative time ("2 hours ago", "yesterday"); every language reads it as "Last check for known vulnerabilities: %@."
- **"Deprecated by Homebrew" vs "No longer supported by Homebrew"** must stay clearly different; it "Deprecato" is developer jargon.
- **"Upgrade" in pt-BR** is "Atualizar", the same verb as update; there's no common separate word.
- **Terminal** uses Apple's name for the app in each language (ターミナル, 终端, 終端機, 터미널, Terminale).

## 1.7 (D-253 to D-255)

- **"Your Mac's warmest tenth of the last 4 weeks: %@ and up."** reads awkwardly everywhere; a native rewording that says "the Mac's warmest 10% of the time" naturally is welcome.
- **"My Mac in %@"** takes a month or a year: de and it use "Mein Mac: %@" / "Il mio Mac: %@" so a year reads right; ja "%@のMac" relies on the date carrying 年/月.
- **"Note"** has no Apple term: ja メモ, zh 备注/備註, nl Notitie, pt-BR Nota.
- **"Earlier"/"Later"** are the arrows' accessibility labels; most languages use plain previous/next.
- **ko "Looking back"** is 돌아보기, close to Your day's 하루 돌아보기.

## D-258: battery watts and unit hovers (2026-10-30)

- **fr:** byte units in the help text are o/s, ko, Mo, Go, matching what `Formatters` shows in French; bits are "bit/s" and "Mbit/s" in de and fr (how plans are sold there), "bps"/"Mbps" elsewhere.
- **it:** "Since %@: average…" uses "Da %1$@:" (the time can carry a date), while the older "Since %@: used…, charged…" says "Dalle"; make the two match. "display included" is "schermo incluso", not the UI's "Monitor".
- **es:** "Desde %1$@" would read better as "Desde las…" before a bare time.
- **ja:** "Since %@: average…" uses a half-width colon, like its older sibling; the notes ask for a full-width ：, so change both together.
- **zh-Hans/zh-Hant:** "Power draw" is 功耗, the same word as in "Apps' power" (App 功耗); 整机功耗 would set the whole-Mac figure apart. zh-Hans uses 比特 for bits; zh-Hant's measure word for a battery (顆) wants a native check.
- **"The charger's rating":** rendered with the formal technical word (定格出力, 额定功率, potência nominal, 정격 출력); nl says "Het vermogen van de lader".
- **Cycle count help:** paraphrased in each language; check it still says "a full battery's worth, at once or over days".

## D-259, D-260: camera and microphone history, downloads never opened (2026-10-30)

- **"Location" as a privacy sensor:** de "Standort" (the UI's other "Location" is "Ort"), fr "Localisation" (UI: "Emplacement"; macOS may say "Position"), ja 位置情報 (UI: 場所). Check against each language's System Settings → Privacy.
- **Camera:** zh-Hans 摄像头 (Apple's privacy wording; the Camera app is 相机); it "Videocamera".
- **"the dots macOS shows in the menu bar":** rendered literally (Punkte, points, ドット, 圆点…); Apple has no UI name for the privacy indicators.
- **"%@ %lld times":** de "%lld-mal" reads stiff for 1 ("1-mal"); ko uses 회 (short labels) not 번 (sentences).
- **ko:** Your day events use the noun ending ("%@이(가) 카메라를 사용함") like the other events; "An app" is 어떤 앱 (maybe 알 수 없는 앱).
- **it/es "Since %@":** "Da %1$@" and "Desde %1$@" (the time can carry a date); the older sibling strings say "Dalle", "desde las".
- **ja/zh-Hant punctuation:** 「ダウンロード」 vs “ダウンロード” and "…" vs "⋯" are already mixed in the existing files.
- **Downloads description (zh):** one long sentence; may read better split.

## D-261, D-262: the Security page, time in calls (2026-10-30)

- **Apple's names**, read by the de/fr/es/it translator from this Mac's own System Settings files (macOS 27): Systemintegritätsschutz, Coupe-feu (fr Firewall), Eingabeüberwachung, Surveillance de l'entrée, Monitorización de los dispositivos de entrada, Monitoraggio input. nl "Systeemintegriteitsbescherming" and pt-BR "Monitoração de Entrada" are from memory; Apple may say "…beveiliging" and "Monitoramento".
- **"Security updates" in Checkup** is plain wording, not the setting's label: macOS 26 says "Install Security Responses and system files", macOS 27 something else, so the English no longer quotes it.
- **zh-Hans FileVault:** 文件保险箱 (Apple's zh_CN name) where ja and zh-Hant keep "FileVault".
- **"Nothing of yours"** (an extension that reaches none of your data) is reworded in every language ("none of your data").
- **"Can turn it on whenever it's open":** de/es/it/nl/pt-BR say "the device" to avoid choosing the camera's or microphone's gender.
- **"Your history"** is browsing history (ja 閲覧履歴…), so it doesn't read as Mactivity's History.
- **Recovery** is from memory everywhere (macOS-Wiederherstellung, récupération macOS, macOS復旧…).
- **ko:** "Bookmarks" 북마크 (Chrome) vs Safari's 책갈피; "In calls" adds a label and colon (통화 시간:).
- **zh-Hant Full Disk Access:** 完整磁碟取用權限 here; the file also has 完整取用磁碟 in older strings.
- **fr "Driver":** "Pilote", where Apple's settings say "gestionnaire".

## Network interfaces and the Security page's partial list (1.9, D-263, D-264)

- **Flags in plain words:** "Has one other end" (POINTOPOINT), "Doesn't look up its neighbors" (NOARP), "Doesn't hear its own broadcasts" (SIMPLEX). de and it keep "Broadcast"; es and fr translate it.
- **"Address lease ends":** es and it use the formal "concesión/concessione", ko the technical 임대; nl and pt-BR reword it as "valid until".
- **"Hardware address":** plainer than the MAC address in its hover. "Joins" is a bridge's member ports. "Other end" is a tunnel's remote address.
- **"Dropped":** ko 폐기됨, nl Verloren. **"Bridge":** fr Pont; check whether it should stay "Bridge". **"Link":** pt-BR keeps "link" where "conexão" is possible.
- **"Used by macOS":** es is feminine plural, heading a group of interfaces. **de "Collisions" hover** is colloquial.
- **"Data received" / "Data sent" and "1 packet"** were written outside the translator pass; check they match the "%@ packets" wording.
- **Addresses / Connection / Traffic (1.9.1)**, the column headings on Network interfaces, were written outside the translator pass.

## The rest of 1.x (2026-11-04, D-271 to D-289)

The translators checked their system terms from memory unless noted, so compare these with the real UI first.

- **All languages:** Device Management, Optimize Mac Storage and Screen Time against System Settings and Photos (fr's and zh's were read from macOS's own tables). "Focus streaks" and "Sits most idle" are coined everywhere; "Focus streaks" mustn't read as macOS's Focus. "No sign of use" and "none found, which isn't proof there were none" must stay exactly as firm as the English.
- **"Forget This Drive":** ja and ko could read as erasing the drive; zh-Hans 忽略 can read as "ignore". It only drops the drive from the list.
- **de, nl "mounted":** aktiviert / geactiveerd may read as "enabled"; verbunden is the alternative in German.
- **de:** "Stoßzeiten" for Busiest hours usually means rush hours; "Markerdatei" isn't a standard term.
- **fr, es:** "marker file" has no standard term; "gently" became "et peu" / "y poco". "Send it on" + "Sunday evening" in the picker reads with the weekday values, unseen.
- **es:** "hacia las %@" is wrong at 1 o'clock, which needs "hacia la 1".
- **it:** "dal %@" should be "dall'8" and "dall'11" on those dates. "Ultimo collegamento" for Last seen is a rewording.
- **pt-BR:** "por volta de %@" has no article; "Análise" for a Wi-Fi scan may read better as "Busca"; "Encaminhamentos" may be long for a column.
- **ja:** "Larger" (大きめ) and the column headings 実際の供給 / 定格 are coined and need checking at their width.
- **ko:** "%@을(를) 위해" reads stiffly with an organization's name; 라이브러리 (~/Library) and 보관함 (the Photos library) must read as different things.
- **nl:** "Doorsturingen" for SSH forwards; "vergelijkbaar opladen" softens "matching" slightly, as does the German.
- **zh-Hant:** Full Disk Access is 完全取用磁碟 in the new keys and older wordings elsewhere; "this Mac" is 這部 Mac in new keys and 這台 Mac in older ones; 資料庫 now means both Database and Library. **zh-Hans:** 信道 for Channel where a macOS table has 频道.
