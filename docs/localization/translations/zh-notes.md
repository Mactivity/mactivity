# Chinese translation notes (zh-Hans, zh-Hant)

Both files validate clean (929/929 keys, 0 problems). zh-Hant uses Taiwan vocabulary as in Apple's
zh_TW (程序, 記憶體, 網路, 檔案, 檔案夾, 資料, 設定, 伺服器, 專案, 連接埠, 執行緒, 預設, 使用者). Items
below need a native reviewer's decision.

## House style choices

- **Spaces around Latin words and placeholders.** The brief said Apple's zh-Hans UI generally doesn't
  put a space between Chinese and Latin text or numbers. Current Apple zh-Hans and zh-Hant do add one
  around Latin words ("关于 Xcode", "iCloud 云盘", "使用 Touch ID"), so I did the same around Latin
  words, `%@` and `%lld`. Compact durations and dates have no space, as in Apple's Battery settings
  ("过去24小时"): `%lld天`, `%1$lld小时%2$lld分`, `12小时`, `每月%lld日`, `每年%1$@%2$lld日`.
- **Quotes:** zh-Hans uses “”, zh-Hant uses 「」, including every `“%@”` in the English source. UI names
  such as “系统设置” and 「系統設定」 are quoted the same way.
- **Punctuation:** full-width ，。：；？ and （）, including "Celsius (°C)" → 摄氏度（°C）. "·" separators and
  "→" menu paths are kept. Items that open a dialog keep the single "…" character.
- **"you":** 你 (not 您) in both languages, as Apple uses.
- **Plurals:** only "other" forms. "All %lld dev servers stopped." and "Stop all %lld dev servers?" drop
  "all", because 全部 1 个 would read wrong when the count is 1 and Chinese has no "one" form to catch it.

## Apple product names (deviates from the brief)

- **Finder is 访达 in zh-Hans.** Apple renamed Finder 访达 in zh_CN (macOS 10.14+), so "Reveal in
  Finder" is 在“访达”中显示. zh-Hant keeps "Finder", as Apple's zh_TW does. If Finder must stay in
  English, change keys 287, 735 and 765 back.
- **Xcode's own menu path stays in English**: "Xcode → Settings → Components". Xcode isn't localized.
- Other Apple names use Apple's translations: 活动监视器/活動監視器, 系统设置/系統設定, 终端/終端機,
  废纸篓/垃圾桶, 钥匙串/鑰匙圈, 访达, 资源库/資料庫 (Library), 应用程序/應用程式, 文稿/文件, 下载/下載項目,
  显示简介/取得資訊, 完全磁盘访问权限/完整磁碟取用權限, 登录项与扩展/登入項目與延伸功能, 隐私与安全性/隱私權與安全性,
  低电量模式/低耗電模式, 菜单栏/選單列, 小组件/小工具, 宗卷/卷宗 (disk volume), 拷贝/拷貝 (Copy).
  Please check: 登录项与扩展 and 登入項目與延伸功能 (the macOS 15+ name of Login Items & Extensions), and
  菜单栏/選單列 as the System Settings pane name in key 524.

## Menu bar abbreviations

| English | zh-Hans | zh-Hant | Note |
|---|---|---|---|
| MEM | 内存 | MEM | Apple's zh-Hant word, 記憶體, is 3 characters. 記憶 on its own means "recollection", so it isn't natural. I kept MEM. RAM is an option many Taiwanese users would recognize. 記憶體 is also an option if the width is acceptable, since the menu bar widens to fit. |
| NET | 网络 | 網路 | |
| TMP | 温度 | 溫度 | |
| BAT | 电池 | 電池 | |

## Terms with no glossary entry

| English | zh-Hans | zh-Hant | Confidence |
|---|---|---|---|
| Energy Impact | 能耗影响 | 能耗影響 | zh-Hans matches Activity Monitor. zh-Hant follows the glossary's 能耗. Apple's zh_TW Activity Monitor may use 能源影響, so please check. |
| Memory Pressure | 内存压力 | 記憶體壓力 | High (Activity Monitor) |
| Wired | 联动内存 | 固定記憶體 | Fairly sure these are Activity Monitor's words. Written in full because 联动 on its own is unclear. |
| App memory | 应用内存 | App 記憶體 | Activity Monitor |
| Compressed / Cached files / Swap used | 已压缩 / 已缓存文件 / 已使用的交换 | 已壓縮 / 已快取的檔案 / 已使用的置換空間 | Activity Monitor style. Please check. |
| Purgeable | 可清除 | 可清除 | Apple storage wording |
| Load average | 平均负载 | 平均負載 | Standard term |
| Thermal pressure | 热压力 | 熱壓力 | Coined, since Apple shows no UI word for it. Levels: 正常 / 中等 / 严重 / 危急 (Nominal / Fair / Serious / Critical). |
| Memory pressure levels | 正常 / 偏高 / 危急 | same | Critical is 危急 in both uses |
| dev server | 开发服务器 | 開發伺服器 | Standard |
| daemon | 守护进程 | 常駐程式 | zh-Hant is uncertain. Alternatives: 守護程式, 背景程式. |
| launch agent / Agent | 启动代理 / 代理程序 | 啟動代理程式 / 代理程式 | Standard |
| privileged helper | 特权辅助程序 | 特權輔助程式 | |
| socket | 套接字 | 通訊端 | Taiwan's standard term is 通訊端 |
| port | 端口 | 連接埠 | |
| Docker image / volume | 镜像 / 数据卷 | 映像檔 / 資料卷 | |
| Runtime (Node, Python) | 运行时 | 執行環境 | |
| alert(s) | 警报 | 警示 | zh-Hans 提醒 is an option, but it clashes with Reminders |
| threshold | 阈值 | 臨界值 | |
| quiet hours | 免打扰时段 | 勿擾時段 | |
| figure (a metric's shown value) | 数值 | 數值 | |
| storage map (sunburst) / Mapping… | 分布图 / 正在分析… | 分佈圖 / 正在分析… | |
| Inspector | 检查器 | 檢閱器 | Apple's words |
| Share (menu) / share card | 共享 / 分享卡片 | 分享 / 分享卡片 | |
| Working (dev server) | 活跃 | 活躍 | |
| Fan "Off" (stopped) | 停转 | 停轉 | |

## Ambiguous source strings

- **"Reading volume…"** (UI): read as a disk volume from `StorageHeader.swift`, so 宗卷/卷宗, not audio 音量.
  "Volume" as a sidebar tab is audio, so 音量.
- **"no ports" mid-sentence** ("frees 1 GB and no ports"): this gives 将释放 1 GB 和 无端口, which reads
  awkwardly in Chinese. A separate key for the no-ports case would read better.
- **"%@ and %@ are free." / "is free."**: both come out as "%1$@ 和 %2$@ 已释放。", because Chinese has no
  singular/plural verb.
- **"%@ of %@"** is used for both a sunburst share ("12% of Library") and used/total memory. The
  translation, "%2$@ 中的 %1$@", works for both but is generic.
- **"Top Apps" / "Busiest"**: translated as "apps using the most" (占用最多的 App), not "popular apps" (热门).
- **"Don't repeat for"**: a short label, 此期间内不重复. It depends on the control next to it.
- **"When"** (Settings section for when alerts are sent) is 发送时间/傳送時間. "When %@" (KeepAlive condition)
  is 当 %@ 时.
- **"Mactivity %1$@ at %2$@"** (share-card file name) drops "at", following Apple's
  screenshot names: "Mactivity 2026-09-25 19.42.10".
- **Weekday and month arguments** ("Weekly on %@", "Yearly in %@") assume the app passes localized
  names (星期一, 3月). If it passes English names, the result mixes Chinese and English.
- **"%lld other"** (file descriptors) is 其他 %lld 个, and "%lld idle/running/stopped" use 个 as the
  counter. Check that these read well in the summary segments.

## Delta of 2026-11-04 (248 keys: developer tools, drives, Wi-Fi channels, profiles, unlocks, notifications)

Checked against macOS 27's own string tables (zh_CN / zh_TW) where a term exists there.

- **Apple's words:** Device Management 设备管理/裝置管理; profile 描述文件/描述檔 (configuration profile 配置描述文件/設定描述檔);
  Screen Time 屏幕时间/螢幕使用時間; Thumbnails 缩略图/縮覽圖; Shared Albums 共享相簿/共享的相簿; Originals 原片/原始檔;
  external drives 外置驱动器/外接磁碟; Forget 忽略/忘記; Mount 装载/裝載; Touch ID 触控 ID/Touch ID.
- **zh-Hant Full Disk Access:** macOS 27 says 完全取用磁碟. The new keys use it; older keys still say 完整取用磁碟 and 完整磁碟取用權限.
- **zh-Hant "this Mac":** new keys use Apple's 這部 Mac; older keys mostly say 這台 Mac.
- **"macOS's log":** macOS 日志 / macOS 記錄檔, following the existing "Logs" 記錄檔; the one older 系統日誌 differs.
- **SSH:** session 会话/工作階段, forward 转发/轉送, tunnel 隧道/通道, arguments 参数/引數, far side 远端/遠端, SOCKS proxy SOCKS 代理/SOCKS 代理伺服器.
- **Wi-Fi channel words:** channel stays 信道/頻道 (Apple's zh_CN table has 频道), band 频段/頻段, width 信道宽度/頻寬. "Heard" is 检测到/偵測到.
- **Coined:** focus streak 专注时段/專注時段, test run 测试运行/測試執行, Sits most idle 最闲/最閒置.
