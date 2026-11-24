# Japanese and Korean translation notes

Files: `ja.json` and `ko.json` in this folder. Each has all 929 keys, and `scripts/translations.py validate` reports 0 problems for both. A second check confirmed that `%u`, `${applicationName}`/`${limit}`/`${metric}`, backtick commands and `%%` also match the English. The validator doesn't check those. These translations were machine-drafted. A native speaker should review them, starting with the items below.

## Conventions used

- **Quotes.** Japanese keeps the curly “%@” quotes, as Apple's macOS Japanese does (“Safari”を強制終了しますか?). Korean uses ‘%@’, Apple's Korean style (‘Safari’을(를) 강제 종료하겠습니까?). Korean particles after a placeholder use Apple's dual forms: 이(가), 을(를), 은(는), (으)로, 과(와).
- **Punctuation.** Japanese uses 、。 and full-width （）： after Japanese text. It uses the half-width `?` in confirmation titles, as Apple JP does (…を終了しますか?). The ellipsis “…” stays on items that open a dialog. The separator “ · ” is kept as-is in both languages.
- **Folder and tab names in Japanese** are quoted with “” (“ダウンロード”, “プロジェクト”タブ), in Apple's help style. Korean leaves them unquoted.
- **Register.** Japanese uses です/ます in sentences and plain nouns for labels. Korean uses -습니다/-십시오 in sentences, short 명사형 forms for status and captions, and short buttons (종료, 중지, 열기).
- **Plurals.** Every plural key has only `other`, and each substitution in the two format keys has only `other`. The two `format` keys reorder their `%#@…@` tokens (projects before servers; total Macs before used Macs). That is safe because each substitution keeps its own argNum.
- **Durations** (`%lldd`, `%lldh`, `%lldm`, `%llds`, `12 h`, `7 d`) are localized to 日/時間/分/秒 and 일/시간/분/초 (e.g. 2時間5分, 2시간 5분). These are wider than “2h 5m”. The menu bar measures localized strings, so it widens instead of clipping.
- **Xcode's menu path** “Xcode → Settings → Components” is kept in English, because Xcode itself isn't localized.

## Menu bar abbreviations (MEM, NET, TMP, BAT)

These stay Latin in both languages. The native short forms are uneven: ja 温度/電池 are 2 characters, but メモリ/ネット are 3 wide characters, and ko 메모리/배터리 are 3. Mixing a 2-character native form with Latin CPU/GPU in the same menu bar would look inconsistent. Latin also keeps the width close to English. A reviewer who prefers native forms could use ja 温度・電池 and ko 온도 for TMP/BAT, but MEM/NET have no natural 2-character form.

## Terms with no Apple glossary entry

| English | ja | ko | Basis |
|---|---|---|---|
| Energy Impact | エネルギー影響 | 에너지 영향 | Activity Monitor's term (ja confirmed per brief; ko believed to match Activity Monitor) |
| Memory Pressure | メモリプレッシャー | 메모리 압력 | Activity Monitor |
| Wired | 確保されているメモリ | 와이어드 메모리 | Activity Monitor (from memory, verify) |
| Compressed | 圧縮 | 압축됨 | Activity Monitor uses 圧縮 / 압축됨 (verify) |
| App memory | アプリケーションメモリ | 앱 메모리 | Activity Monitor (verify) |
| Purgeable | パージ可能 | 제거 가능 | Finder/Storage wording; ko could also be 삭제 가능 |
| Swap used | 使用済みスワップ | 사용된 스왑 | Activity Monitor-style |
| Load average | ロードアベレージ | 부하 평균 | Standard technical terms (not in Activity Monitor) |
| Thermal pressure | 熱負荷 | 열 부하 | No Apple UI term. Levels: Nominal 正常/정상, Fair 中程度/보통, Serious 高い/높음, Critical 危険/위험 |
| Memory status Elevated | 上昇 | 상승 | Not Apple wording |
| dev server | 開発サーバ | 개발 서버 | Apple JP drops the long mark (サーバ) |
| daemon / agent | デーモン / エージェント | 데몬 / 에이전트 | Standard. “launch agents” = 起動エージェント / 실행 에이전트 |
| CPU Idle / User / System | アイドル状態 / ユーザ / システム | 대기 / 사용자 / 시스템 | Activity Monitor CPU pane (ko 대기 from memory, verify) |
| Idle (dev server) | アイドル | 유휴 | Different word from the CPU “Idle” on purpose |
| Quiet hours | 通知停止時間帯 | 알림 끔 시간 | Coined |
| Full Disk Access | フルディスクアクセス | 전체 디스크 접근 권한 | System Settings |
| Login Items & Extensions | ログイン項目と機能拡張 | 로그인 항목 및 확장 프로그램 | System Settings (verify the macOS 26/27 pane name) |
| Cycle count | 充放電回数 | 사이클 수 | System Information |
| Menu bar | メニューバー | 메뉴 막대 | Apple |
| Startup (tab) | 起動項目 | 시동 항목 | Coined. Startup disk = 起動ディスク / 시동 디스크 |
| Appearance → System | 自動 | 자동 | Follows Apple's Appearance “Auto” |
| Docker states | 作成済み, 実行中, 一時停止中, 再起動中, 削除中, 終了済み, 異常停止 (Dead) | 생성됨, 실행 중, 일시 정지됨, 다시 시작하는 중, 제거 중, 종료됨, 비정상 중지 | “Dead” has no good native word; a reviewer may prefer leaving Docker states in English |
| Mute (per-app audio) | 消音 | 음소거 | Apple |

## Ambiguous or context-dependent source strings

- **“Muted apps”** (UI): the code shows it is the Alerts setting for apps whose alerts are silenced, not muted audio. It was translated as 通知をオフにしたアプリ / 알림을 끈 앱, and so was the same phrase in “Thresholds, quiet hours, and muted apps…”. “Muted” and “Mute %@” in the Volume tab use 消音 / 음소거.
- **“It tells you”** is an onboarding heading. It was rendered as 問題があれば通知 / 문제가 생기면 알림.
- **“Power”** (widget) is the figure title shown when there is no battery, so it is the power source: 電源 / 전원.
- **“Starts on”** is the label for launchd on-demand triggers: 起動のきっかけ / 시작 조건.
- **“When %@”** has a verbatim plist condition key as its argument, so it is written as 条件：%@ / 조건: %@ to avoid grammar around an English token.
- **“All %lld dev servers stopped.” / “Stop all %lld dev servers?”** have a different English `one` form (no “all”). Japanese and Korean only have `other`, so the text reads “all dev servers (N)”: すべての開発サーバ（%lld個）… / 모든 개발 서버(%lld개)…. This is still correct when N is 1.
- **“Mactivity %@ at %@”** (share card file name) follows the ja/ko macOS screenshot name pattern, which uses no “at”: `Mactivity %1$@ %2$@`.
- **“no ports”** mid-sentence (“frees 1 GB and no ports”) became ポート0個 / 포트 0개 so the sentence still reads.
- **“Above” / “Writing above” / “Grows by” / “For”** are short picker labels in alert rules: 超過 / 書き込み超過 / 増加量 / 継続時間 (ko 초과 / 쓰기 초과 / 증가량 / 지속 시간). Check them in context.
- **Alert rule summaries with ≥** keep the symbol and move the time window into parentheses: ≥ %1$@（%2$@の平均）.
- **Stale source strings, possibly:** some onboarding strings in `source.json` are shorter than the literals now in `OnboardingView.swift`. One example is “Every helper process is counted…” against the catalog's “Every helper is counted…”. Re-export after `make sync-strings` if the catalogs have moved on.
- **“%1$@ cores (%2$lld)”**: the cluster name (e.g. Performance/Efficiency) comes from elsewhere and isn't in the catalogs. If it stays English, “%1$@コア” will mix languages.

## Terms added with the 1.x roadmap strings

| English | ja | ko | Basis |
|---|---|---|---|
| Device Management | デバイス管理 | 기기 관리 | System Settings (from memory, verify) |
| Configuration profile | 構成プロファイル | 구성 프로파일 | Apple |
| SSH forward | 転送 | 포워딩 | Standard; ko keeps the loanword developers use. “far side” = リモート側 / 원격 측 |
| Unlocks | ロック解除 | 잠금 해제 | Same word for the count and the action |
| Chargers: Rating / Delivers | 定格 / 実際の供給 | 정격 / 실제 공급 | Coined column headings |
| Like for like | 同じ条件では | 같은 조건에서 | Coined |
| Your channel | 使用中のチャンネル | 현재 채널 | Not “my”: a channel the Mac is on |
| heard (Wi-Fi scan) | 検出 | 감지 | “Sounds quieter” = 空いているようです / 더 한산한 것으로 보입니다 |
| Focus streaks | 集中の連続時間 | 연속 집중 시간 | Coined |
| Photos library | 写真ライブラリ | 사진 보관함 | Apple. ko uses 보관함 for Photos, 라이브러리 for the ~/Library folder |
| around (an hour) | %@頃 | %@경 | |
