import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ru = "ru"

    var id: String { rawValue }

    static func resolveSystemLanguage(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        for raw in preferredLanguages {
            let lang = raw.lowercased()
            if lang.hasPrefix("zh-hant")
                || lang.hasPrefix("zh_hant")
                || lang == "zh-tw" || lang.hasPrefix("zh-tw-") || lang.hasPrefix("zh_tw")
                || lang == "zh-hk" || lang.hasPrefix("zh-hk-") || lang.hasPrefix("zh_hk")
                || lang == "zh-mo" || lang.hasPrefix("zh-mo-") || lang.hasPrefix("zh_mo") {
                return .zhHant
            }
            if lang == "zh" || lang.hasPrefix("zh-") || lang.hasPrefix("zh_") {
                return .zhHans
            }
            if lang == "ru" || lang.hasPrefix("ru-") || lang.hasPrefix("ru_") {
                return .ru
            }
            if lang == "en" || lang.hasPrefix("en-") || lang.hasPrefix("en_") {
                return .en
            }
        }
        return .en
    }

    var resolved: AppLanguage {
        switch self {
        case .system:
            return Self.resolveSystemLanguage()
        case .zhHans, .zhHant, .en, .ru:
            return self
        }
    }

    var isEnglish: Bool {
        resolved == .en
    }

    func displayName(in current: AppLanguage) -> String {
        switch self {
        case .system:
            switch current.resolved {
            case .zhHans: return "跟随系统"
            case .zhHant: return "跟隨系統"
            case .ru: return "Системный"
            case .en, .system: return "System"
            }
        case .zhHans:
            return "简体中文"
        case .zhHant:
            return "繁體中文"
        case .en:
            return "English"
        case .ru:
            return "Русский"
        }
    }
}

enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedLanguage: AppLanguage = .system

    static var current: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedLanguage
        }
        set {
            lock.lock()
            storedLanguage = newValue
            lock.unlock()
        }
    }

    static func t(_ zhHans: String, _ en: String, _ lang: AppLanguage = L10n.current) -> String {
        switch lang.resolved {
        case .zhHans:
            return zhHans
        case .zhHant:
            return zhHantTable[en] ?? zhHans
        case .ru:
            return ruTable[en] ?? en
        case .en, .system:
            return en
        }
    }

    static func t(
        zhHans: String,
        zhHant: String,
        en: String,
        ru: String,
        _ lang: AppLanguage = L10n.current
    ) -> String {
        switch lang.resolved {
        case .zhHans:
            return zhHans
        case .zhHant:
            return zhHant
        case .ru:
            return ru
        case .en, .system:
            return en
        }
    }

    private static let zhHantTable: [String: String] = [
        "0.1s Hot Update": "0.1s 免重建熱更新",
        "0.1s Hot Update: Changing ports, scheme, or NO_PROXY updates external proxy.env directly without copying or re-signing.": "0.1s 免重建熱更新：僅修改代理連接埠、協定或 NO_PROXY 列表時，將直接寫入外置 proxy.env，無需重複複製或重簽署。",
        "1-year (52-week) token heatmap with clickable daily details": "近一年（52 週）Token 活躍熱力圖（支援單日明細點擊）",
        "14-Day Trend": "近 14 日趨勢",
        "14-day token bar chart & model breakdown donut": "近 14 日 Token 趨勢長條圖與模型佔比環形圖",
        "2. SOCKS5 Handshake (05 01 00)": "2. SOCKS5 協定交握 (05 01 00)",
        "20-Week Heatmap": "近 20 週熱力圖",
        "20-week token heatmap, daily trend & estimated API billing": "20 週 Token 活躍熱力圖、每日趨勢與估算 API 帳單",
        "3-Stage Proxy Diagnostics": "三階代理健康診斷",
        "3-channel TUN-free proxy, live health chain & runtime launcher": "三通道免 TUN 代理、即時健康鏈路與 Runtime 副本啟動",
        "3. Internet via Proxy (generate_204)": "3. 代理外網連通 (generate_204)",
        "3. Net": "3. 外網",
        "30 Days": "近 30 天",
        "7 Days": "近 7 天",
        "Active Context": "目前工作階段上下文",
        "Active Session Context": "目前工作階段上下文",
        "After launching Antigravity (or Pilot runtime), this view reads ~/.gemini/antigravity/daemon/ and connects to the local loopback service to show live context & model quotas.": "啟動 Antigravity（或 Pilot 代理副本）後，這裡將自動讀取 ~/.gemini/antigravity/daemon/ 並直連本機迴環服務展示上下文視窗與模型配額。",
        "All": "全部",
        "Antigravity In-App Dashboard Plugin": "Antigravity 應用內看板外掛",
        "Antigravity Is Not Running": "Antigravity 目前未執行",
        "Antigravity Is Running": "偵測到 Antigravity 正在執行",
        "Antigravity Pilot Runtime": "Antigravity Pilot 代理副本",
        "Antigravity Pilot Tips": "Antigravity Pilot 使用提示",
        "Antigravity did not exit within 5s. Quit with Cmd + Q and try again.": "舊版 Antigravity 未能在 5 秒內結束，請手動 Cmd + Q 結束後重試。",
        "Antigravity is not running": "未偵測到執行中的 Antigravity",
        "App Icon Style": "應用圖示樣式",
        "Applies to the proxied runtime copy only; Pilot keeps its own icon.": "僅影響代理版 Runtime 副本，伴侶本身保持 Pilot 圖示。",
        "Approval needed in System Settings → Login Items": "需在系統設定 → 登入項目中允許",
        "Auth Required": "需要驗證",
        "Build & Launch": "重建副本並啟動",
        "Built on official MCP Apps (SEP-1865) and native Swift backend with zero JS injection and automatic light/dark theme.": "基於官方 MCP Apps (SEP-1865) 協定與原生 Swift 後端建置，零 JS 注入，自動跟隨亮暗主題。",
        "Bundled MCP plugin assets are missing in this app bundle. Rebuild via ./build.sh.": "目前應用套件未內建 MCP 外掛產物，請透過 ./build.sh 重新建置。",
        "Cache Hit Rate": "快取命中率",
        "Channel Summary & Maintenance": "通道摘要與副本維護",
        "Chat Top-Right + · Pilot Live Monitor": "對話右上角 + ·「Pilot 即時監控」",
        "Check local proxy 3-stage health status": "檢查目前本機代理三階健康狀態",
        "Check numeric proxy IP (e.g. 127.0.0.1) and port range (1-65535).": "請檢查代理 IP（如 127.0.0.1）與連接埠範圍（1-65535）。",
        "Checking Antigravity installation...": "正在檢查本機 Antigravity 狀態...",
        "Checking proxy ports...": "檢查代理連接埠...",
        "Checking...": "偵測中...",
        "Classic": "原汁原味",
        "Click a cell for day details": "點擊方格查看單日明細",
        "Click to view Live Monitor": "點擊查看即時監控",
        "Config Dir": "設定目錄",
        "Copying original Antigravity...": "複製原版 Antigravity...",
        "Core Proxy Settings": "核心代理設定",
        "Custom": "自訂",
        "Deployment & Runtime Notes": "外掛部署與執行說明",
        "Disabled": "未開啟",
        "Distinct": "Dock 易區分",
        "ENV Port": "ENV 連接埠",
        "ENV Port Error": "ENV 連接埠異常",
        "ENV Scheme": "ENV 協定",
        "ENV proxy port must be between 1 and 65535.": "環境變數代理連接埠必須在 1 到 65535 之間。",
        "ENV proxy scheme must be http or socks5.": "環境變數代理協定只能是 http 或 socks5。",
        "Embed live telemetry & billing dashboard directly inside Antigravity": "將即時監控與帳單看板直接嵌入 Antigravity 應用內部",
        "Est. API Cost": "估算 API 帳單",
        "Estimated API cost across Today / 7d / 30d / All": "今日 / 7 天 / 30 天 / 全部週期估算 API 帳單",
        "Estimated via API pricing, not actual billing": "參考 API 定價估算，非實際扣費",
        "Extracting entitlements & re-signing...": "擷取原版 Entitlements 並重簽署...",
        "F": "五",
        "Failed to parse ASAR header": "無法解析 header",
        "Fast hot-updating config...": "極速熱更新設定（免重建）...",
        "File too small": "檔案過小",
        "Force Full Rebuild": "強制完整重建副本",
        "Generating app icon...": "產生圖示...",
        "Gracefully quitting running Antigravity...": "正在優雅結束執行中的 Antigravity...",
        "Handshake Timeout": "交握逾時",
        "Header size out of bounds": "header size 越界",
        "Hide Sidebar (⌥⌘S)": "收起側邊欄 (⌥⌘S)",
        "Hide the macOS top menu bar icon; closing the main window will quit Pilot.": "關閉後不顯示 macOS 頂部選單列小圖示；關閉主視窗將直接結束 Pilot。",
        "Hot-updated config & launched": "已熱更新設定並啟動",
        "Hover for details": "懸停查看當日",
        "In-App Dashboard Plugin": "Antigravity 應用內看板",
        "In-App Plugin": "應用內外掛",
        "In-app proxy health diagnostics, live session context, shared model quota pools, and 1-year usage & billing dashboard.": "Antigravity 應用內代理健康探測、即時工作階段上下文、模型共享配額池與全年用量帳單看板。",
        "Incomplete": "不完整",
        "Inspect live session context & model quota pools via local Language Server": "直連本機 Language Server 查看即時上下文構成與配額池",
        "Install": "一鍵安裝",
        "Install Dir": "安裝目錄",
        "Install to Antigravity": "安裝到 Antigravity",
        "Installing proxy components...": "寫入代理元件...",
        "Invalid Config": "設定無效",
        "Keep in Dock: Right-click the running icon in Dock → Options → Keep in Dock for one-click launch.": "Dock 單圖示秒開：首次啟動 Pilot 後，右鍵 Dock 上執行中的圖示 →「選項 → 在 Dock 中保留」，日常即可秒開。",
        "Language": "介面語言",
        "Language, NO_PROXY bypass rules, menu bar companion & maintenance": "介面語言、NO_PROXY 繞過規則、選單列常駐伴侶與副本維護",
        "Launch Antigravity Pilot": "啟動 Antigravity Pilot",
        "Launch Antigravity Pilot at login": "開機登入時自動啟動 Antigravity Pilot",
        "Launch Pilot": "啟動 Pilot",
        "Launch at login enabled": "已開啟登入時啟動",
        "Launching Antigravity Pilot...": "啟動 Antigravity Pilot...",
        "Left Sidebar · Pilot Usage & Billing": "左側邊欄 ·「Pilot 用量與帳單」",
        "Less": "低",
        "Live Monitor": "即時監控",
        "Live context gauge, cache hit rate, TTFT & tok/s": "目前工作階段上下文佔用環、快取命中率、TTFT 與生成速度",
        "Local day": "本機自然日",
        "M": "一",
        "MCP assets not bundled in this build": "目前建置套件未包含 MCP 產物",
        "Manage ›": "管理 ›",
        "Menu Bar & Login Item": "選單列與開機自啟",
        "Minimize to Menu Bar": "縮入選單列",
        "Model": "模型",
        "Model Calls": "模型呼叫次數",
        "Model Quota Pool": "模型配額池",
        "More": "高",
        "Move app to /Applications first": "請先將應用移至 /Applications",
        "NO_PROXY Bypass Rules": "NO_PROXY 繞過規則",
        "No Internet": "外網未通",
        "No active session context": "暫無活躍工作階段上下文",
        "No model quota information available yet.": "暫未取得模型配額資訊。",
        "No model usage recorded in the selected session.": "目前選定工作階段暫無模型呼叫紀錄。",
        "No model usage recorded in this period.": "所選週期暫無模型呼叫紀錄。",
        "No usage data in the last 14 days": "暫無近 14 日用量紀錄",
        "Non-invasive: /Applications/Antigravity.app remains untouched; when the menu bar icon is enabled, closing this window minimizes monitoring to the menu bar.": "零入侵原版應用：/Applications/Antigravity.app 始終保持唯讀不改動；開啟頂部選單列圖示時，關閉本視窗後監控縮入選單列。",
        "Not Installed": "未安裝",
        "Not SOCKS5": "非 SOCKS5 連接埠",
        "Not connected to quota service": "未連接到模型配額服務",
        "Not installed (sidebar view + aux pane)": "未安裝（支援邊欄全螢幕 + 對話輔助面板）",
        "Open Config Folder": "開啟設定目錄",
        "Open Main Window...": "開啟主視窗...",
        "Open Pilot Live Monitor to inspect active session context & model quotas": "開啟 Pilot 即時監控面板查看目前工作階段上下文與配額",
        "Open Pilot Usage & Billing dashboard to review token usage & estimated cost": "開啟 Pilot 用量與帳單看板統計近期 Token 與估算費用",
        "Open Window": "開啟主視窗",
        "Original": "原版圖示",
        "Original & Pilot Compatible": "原版 & Pilot 副本通用",
        "Original /Applications/Antigravity.app not found": "未偵測到原版 /Applications/Antigravity.app",
        "Original Antigravity": "原版 Antigravity",
        "Output Speed": "輸出速度",
        "Patching Electron icon...": "Patch Electron 圖示...",
        "Pilot Icon": "Pilot 識別",
        "Pilot Live Monitor": "Pilot 即時監控",
        "Pilot Usage & Billing": "Pilot 用量與帳單",
        "Presets": "常用預設",
        "Primary Pool": "主配額池",
        "Primary Quota Pool": "主配額池餘量",
        "Probing local port, SOCKS5 handshake, and internet connectivity...": "正在執行本機連接埠、SOCKS5 交握與出網驗證...",
        "Proxy": "代理",
        "Proxy Host": "代理 Host",
        "Proxy Overview": "代理概覽",
        "Proxy host cannot be empty.": "代理 host 不能為空。",
        "Proxy host must be a numeric IP (e.g. 127.0.0.1 or ::1) or localhost.": "代理 Host 需為數字 IP（如 127.0.0.1 或 ::1）或 localhost。",
        "Quit": "結束",
        "Quit & Hot Restart": "結束舊程序並熱重啟",
        "Quit & Launch": "優雅結束並啟動",
        "Quit & Rebuild": "結束舊程序並重建",
        "Quit Antigravity Pilot": "結束 Antigravity Pilot",
        "Quit Pilot": "結束 Pilot",
        "Re-run 3-stage proxy health probe": "立即重測三階代理健康",
        "Re-sync": "重新同步",
        "Re-test": "重測",
        "Read-only proxy params & live 3-stage probe (TCP / SOCKS5 / 204)": "本機代理唯讀參數與三階健康即時探測（TCP / SOCKS5 / 204）",
        "Ready": "準備就緒",
        "Rebuild Required": "需重建/重簽副本",
        "Rebuilt runtime & launched": "已重建副本並啟動",
        "Refresh": "重新整理狀態",
        "Refresh Monitor & Proxy Now": "立即重新整理監控與代理狀態",
        "Refresh live monitor": "重新整理即時監控",
        "Rescan session transcripts": "重新掃描工作階段用量",
        "Reset Defaults": "恢復預設",
        "Reset time unknown": "未知重置時間",
        "Resetting soon": "即將重置",
        "Runtime copy not built yet. Save & launch from Proxy Overview first.": "尚未產生代理副本，請先在「代理概覽」中儲存並啟動。",
        "SOCKS5 Port": "SOCKS5 連接埠",
        "SOCKS5 Ready": "SOCKS5 就緒",
        "SOCKS5 handshake OK, invalid probe target host.": "SOCKS5 交握正常，目標探測網域無效。",
        "SOCKS5 port must be between 1 and 65535.": "SOCKS5 連接埠必須在 1 到 65535 之間。",
        "Save & Quick Launch": "儲存並極速啟動",
        "Settings": "進階設定",
        "Shared quota pool bars & reset countdown (5s auto-refresh)": "模型共享配額池餘量與重置倒數（可見時 5 秒自動更新）",
        "Show Menu Bar Icon": "顯示頂部選單列圖示",
        "Show Monitor & Billing inside Antigravity": "在 Antigravity 應用內顯示監控與帳單",
        "Show Sidebar (⌥⌘S)": "展開側邊欄 (⌥⌘S)",
        "Show live context & quota metrics in menu bar (e.g. 188K · 89%)": "選單列顯示即時上下文與配額指標（如 188K · 89%）",
        "Show top menu bar icon (minimize to menu bar when window closes)": "顯示頂部選單列圖示（關閉視窗後縮入選單列常駐監控）",
        "Supports LAN CIDRs (e.g. 192.168.0.0/16) and domain suffixes (e.g. *.local) across dylib hook, env vars, and Chromium.": "支援區域網路 CIDR（如 192.168.0.0/16）與網域尾碼（如 *.local），同時作用於 dylib hook、環境變數與 Chromium 主程序。",
        "Swapping runtime bundle...": "原子替換 runtime...",
        "TTFT": "首字延遲 (TTFT)",
        "Thinking / Reply": "思考 / 回覆",
        "Today": "今日",
        "Today's Usage": "今日消耗",
        "Total Tokens": "總消耗 Token",
        "Unavailable": "不可用",
        "Uninstall": "解除安裝",
        "Uninstalled Antigravity in-app dashboard plugin.": "已解除安裝 Antigravity 應用內看板外掛。",
        "Unknown": "未知",
        "Unreachable": "連接埠未連通",
        "Update": "更新外掛",
        "Updating bundle info (original icon)...": "修改 bundle 資訊（保留原版圖示）...",
        "Updating bundle info...": "修改 bundle 資訊...",
        "Usage & Billing": "用量與帳單",
        "View 3-stage diagnostic details": "查看三階診斷詳情",
        "View tips": "查看使用說明",
        "W": "三",
        "Waiting for Antigravity": "等待 Antigravity 啟動",
        "Writing external proxy config...": "寫入外置代理設定...",
        "aux_pane side panel": "aux_pane 輔助面板",
        "global full-screen view": "global 全螢幕檢視",
        "• Automatically notifies running Antigravity Language Server to reload after install/update with zero restart; refreshes run via app-only tools and consume 0 tokens.": "• 安裝或更新後會自動通知執行中的 Antigravity Language Server 重載外掛，無需重啟應用；重新整理資料時透過 App-only 工具執行，不消耗任何模型 Token。",
        "• To avoid self-restart disconnects inside Antigravity, the in-app panel keeps proxy config read-only + live probing; edit ports or bypass rules in Proxy Overview / Settings.": "• 為防止在 Antigravity 內部自我重啟造成連線中斷，應用內面板保持代理設定唯讀 + 即時三階探測；修改連接埠或繞過規則請回到「代理概覽 / 進階設定」。",
        "≈ %.1fx $20 Pro/mo": "≈ %.1fx $20 Pro 月費"
    ]

    private static let ruTable: [String: String] = [
        "0.1s Hot Update": "0.1с Хот-апдейт",
        "0.1s Hot Update: Changing ports, scheme, or NO_PROXY updates external proxy.env directly without copying or re-signing.": "Обновление за 0.1с: изменение портов, протокола или NO_PROXY обновляет внешний proxy.env без копирования и переподписи.",
        "1-year (52-week) token heatmap with clickable daily details": "Годовая (52 нед.) карта токенов с деталями по дням",
        "14-Day Trend": "Тренд за 14 дн.",
        "14-day token bar chart & model breakdown donut": "График токенов за 14 дней и распределение по моделям",
        "2. SOCKS5 Handshake (05 01 00)": "2. Рукопожатие SOCKS5 (05 01 00)",
        "20-Week Heatmap": "Карта за 20 нед.",
        "20-week token heatmap, daily trend & estimated API billing": "Тепловая карта за 20 недель, тренд и оценка стоимости API",
        "3-Stage Proxy Diagnostics": "3-этапная диагностика прокси",
        "3-channel TUN-free proxy, live health chain & runtime launcher": "3-канальный прокси без TUN, проверка канала и запуск копии",
        "3. Internet via Proxy (generate_204)": "3. Выход в сеть (generate_204)",
        "3. Net": "3. Сеть",
        "30 Days": "30 дн.",
        "7 Days": "7 дн.",
        "Active Context": "Текущий контекст",
        "Active Session Context": "Контекст текущей сессии",
        "After launching Antigravity (or Pilot runtime), this view reads ~/.gemini/antigravity/daemon/ and connects to the local loopback service to show live context & model quotas.": "После запуска Antigravity (или копии Pilot) здесь читается ~/.gemini/antigravity/daemon/ и отображаются контекст и квоты.",
        "All": "Все",
        "Antigravity In-App Dashboard Plugin": "Встроенный плагин панели",
        "Antigravity Is Not Running": "Antigravity не запущен",
        "Antigravity Is Running": "Antigravity уже запущен",
        "Antigravity Pilot Runtime": "Копия Antigravity Pilot",
        "Antigravity Pilot Tips": "Подсказки Antigravity Pilot",
        "Antigravity did not exit within 5s. Quit with Cmd + Q and try again.": "Antigravity не завершился за 5с. Нажмите Cmd + Q вручную и повторите.",
        "Antigravity is not running": "Antigravity не запущен",
        "App Icon Style": "Иконка приложения",
        "Applies to the proxied runtime copy only; Pilot keeps its own icon.": "Меняет только иконку runtime-копии; сам Pilot сохраняет свою.",
        "Approval needed in System Settings → Login Items": "Разрешите в Настройках → Объекты входа",
        "Auth Required": "Нужна авторизация",
        "Build & Launch": "Собрать и запуск",
        "Built on official MCP Apps (SEP-1865) and native Swift backend with zero JS injection and automatic light/dark theme.": "Построен на MCP Apps (SEP-1865) и нативном Swift без JS-инъекций, с поддержкой светлой/тёмной темы.",
        "Bundled MCP plugin assets are missing in this app bundle. Rebuild via ./build.sh.": "В пакете отсутствуют ресурсы MCP-плагина. Пересоберите через ./build.sh.",
        "Cache Hit Rate": "Кэш-хит",
        "Channel Summary & Maintenance": "Сводка каналов и обслуживание",
        "Chat Top-Right + · Pilot Live Monitor": "Кнопка + в чате · Pilot Монитор",
        "Check local proxy 3-stage health status": "Проверить состояние локального прокси (3 этапа)",
        "Check numeric proxy IP (e.g. 127.0.0.1) and port range (1-65535).": "Проверьте IP прокси (напр. 127.0.0.1) и диапазон портов (1-65535).",
        "Checking Antigravity installation...": "Проверка установки Antigravity...",
        "Checking proxy ports...": "Проверка портов прокси...",
        "Checking...": "Проверка...",
        "Classic": "Классика",
        "Click a cell for day details": "Нажмите ячейку для деталей",
        "Click to view Live Monitor": "Открыть Монитор",
        "Config Dir": "Папка настроек",
        "Copying original Antigravity...": "Копирование Antigravity...",
        "Core Proxy Settings": "Настройки прокси",
        "Custom": "Свой",
        "Deployment & Runtime Notes": "Установка и работа плагина",
        "Disabled": "Отключено",
        "Distinct": "Отличимый",
        "ENV Port": "Порт ENV",
        "ENV Port Error": "Ошибка порта ENV",
        "ENV Scheme": "Протокол ENV",
        "ENV proxy port must be between 1 and 65535.": "Порт ENV-прокси должен быть от 1 до 65535.",
        "ENV proxy scheme must be http or socks5.": "Протокол ENV-прокси: только http или socks5.",
        "Embed live telemetry & billing dashboard directly inside Antigravity": "Встроенный мониторинг и учёт расходов прямо внутри Antigravity",
        "Est. API Cost": "Оценка API",
        "Estimated API cost across Today / 7d / 30d / All": "Оценка расходов API за Сегодня / 7 дн. / 30 дн. / Все",
        "Estimated via API pricing, not actual billing": "Оценка по тарифам API, не реальный счёт",
        "Extracting entitlements & re-signing...": "Извлечение прав и подпись...",
        "F": "Пт",
        "Failed to parse ASAR header": "Ошибка разбора заголовка ASAR",
        "Fast hot-updating config...": "Быстрое обновление конфига...",
        "File too small": "Файл слишком мал",
        "Force Full Rebuild": "Полная пересборка",
        "Generating app icon...": "Генерация иконки...",
        "Gracefully quitting running Antigravity...": "Завершение работы Antigravity...",
        "Handshake Timeout": "Таймаут SOCKS5",
        "Header size out of bounds": "Размер заголовка вне границ",
        "Hide Sidebar (⌥⌘S)": "Скрыть панель (⌥⌘S)",
        "Hide the macOS top menu bar icon; closing the main window will quit Pilot.": "Скрыть иконку в строке меню macOS; закрытие окна завершит Pilot.",
        "Hot-updated config & launched": "Конфиг обновлён и запущен",
        "Hover for details": "Наведите для деталей",
        "In-App Dashboard Plugin": "Плагин панели в Antigravity",
        "In-App Plugin": "Плагин в IDE",
        "In-app proxy health diagnostics, live session context, shared model quota pools, and 1-year usage & billing dashboard.": "Диагностика прокси, контекст сессии, общие квоты моделей и статистика расходов за год внутри Antigravity.",
        "Incomplete": "Неполный",
        "Inspect live session context & model quota pools via local Language Server": "Просмотр контекста и квот моделей через локальный Language Server",
        "Install": "Установить",
        "Install Dir": "Папка плагина",
        "Install to Antigravity": "Установить в IDE",
        "Installing proxy components...": "Установка компонентов прокси...",
        "Invalid Config": "Неверный конфиг",
        "Keep in Dock: Right-click the running icon in Dock → Options → Keep in Dock for one-click launch.": "Закрепить в Dock: ПКМ по иконке в Dock → Параметры → Оставить в Dock для быстрого запуска.",
        "Language": "Язык интерфейса",
        "Language, NO_PROXY bypass rules, menu bar companion & maintenance": "Язык, исключения NO_PROXY, строка меню и обслуживание",
        "Launch Antigravity Pilot": "Запустить Antigravity Pilot",
        "Launch Antigravity Pilot at login": "Запускать Antigravity Pilot при входе",
        "Launch Pilot": "Запуск Pilot",
        "Launch at login enabled": "Автозапуск включён",
        "Launching Antigravity Pilot...": "Запуск Antigravity Pilot...",
        "Left Sidebar · Pilot Usage & Billing": "Боковая панель · Расход и счёт",
        "Less": "Меньше",
        "Live Monitor": "Монитор",
        "Live context gauge, cache hit rate, TTFT & tok/s": "Индикатор контекста, кэш-хит, TTFT и скорость генерации",
        "Local day": "Лок. сутки",
        "M": "Пн",
        "MCP assets not bundled in this build": "Ресурсы MCP не включены в сборку",
        "Manage ›": "Настроить ›",
        "Menu Bar & Login Item": "Строка меню и автозапуск",
        "Minimize to Menu Bar": "В строку меню",
        "Model": "Модель",
        "Model Calls": "Вызовы API",
        "Model Quota Pool": "Пул квот моделей",
        "More": "Больше",
        "Move app to /Applications first": "Сначала перенесите в /Applications",
        "NO_PROXY Bypass Rules": "Исключения NO_PROXY",
        "No Internet": "Нет сети",
        "No active session context": "Нет активного контекста",
        "No model quota information available yet.": "Данные о квотах моделей пока недоступны.",
        "No model usage recorded in the selected session.": "В выбранной сессии нет вызовов моделей.",
        "No model usage recorded in this period.": "За выбранный период нет вызовов моделей.",
        "No usage data in the last 14 days": "Нет данных за последние 14 дней",
        "Non-invasive: /Applications/Antigravity.app remains untouched; when the menu bar icon is enabled, closing this window minimizes monitoring to the menu bar.": "Без вмешательства: /Applications/Antigravity.app не изменяется; при включённой иконке в меню закрытие окна сворачивает Pilot туда.",
        "Not Installed": "Не установлен",
        "Not SOCKS5": "Не SOCKS5 порт",
        "Not connected to quota service": "Нет подключения к сервису квот",
        "Not installed (sidebar view + aux pane)": "Не установлен (боковая панель + панель чата)",
        "Open Config Folder": "Открыть папку",
        "Open Main Window...": "Открыть главное окно...",
        "Open Pilot Live Monitor to inspect active session context & model quotas": "Открыть Pilot Монитор для просмотра контекста и квот моделей",
        "Open Pilot Usage & Billing dashboard to review token usage & estimated cost": "Открыть панель расхода и счёта Pilot для анализа токенов и стоимости",
        "Open Window": "Открыть окно",
        "Original": "Оригинал",
        "Original & Pilot Compatible": "Для оригинала и Pilot",
        "Original /Applications/Antigravity.app not found": "Не найден /Applications/Antigravity.app",
        "Original Antigravity": "Оригинал Antigravity",
        "Output Speed": "Скорость",
        "Patching Electron icon...": "Патчинг иконки Electron...",
        "Pilot Icon": "Значок Pilot",
        "Pilot Live Monitor": "Pilot Монитор",
        "Pilot Usage & Billing": "Pilot Расход и счёт",
        "Presets": "Пресеты",
        "Primary Pool": "Основной пул",
        "Primary Quota Pool": "Основной пул квот",
        "Probing local port, SOCKS5 handshake, and internet connectivity...": "Проверка локального порта, SOCKS5 и выхода в интернет...",
        "Proxy": "Прокси",
        "Proxy Host": "Хост прокси",
        "Proxy Overview": "Прокси",
        "Proxy host cannot be empty.": "Хост прокси не может быть пустым.",
        "Proxy host must be a numeric IP (e.g. 127.0.0.1 or ::1) or localhost.": "Хост прокси должен быть IP-адресом (напр. 127.0.0.1 или ::1) или localhost.",
        "Quit": "Выход",
        "Quit & Hot Restart": "Закрыть и перезапустить",
        "Quit & Launch": "Закрыть и запуск",
        "Quit & Rebuild": "Закрыть и пересобрать",
        "Quit Antigravity Pilot": "Выйти из Antigravity Pilot",
        "Quit Pilot": "Выйти из Pilot",
        "Re-run 3-stage proxy health probe": "Повторить 3-этапную проверку",
        "Re-sync": "Синхр.",
        "Re-test": "Тест",
        "Read-only proxy params & live 3-stage probe (TCP / SOCKS5 / 204)": "Параметры прокси и 3-этапная проверка (TCP / SOCKS5 / 204)",
        "Ready": "Готово",
        "Rebuild Required": "Нужна сборка",
        "Rebuilt runtime & launched": "Собрано и запущено",
        "Refresh": "Обновить",
        "Refresh Monitor & Proxy Now": "Обновить монитор и прокси",
        "Refresh live monitor": "Обновить монитор",
        "Rescan session transcripts": "Пересканировать логи сессий",
        "Reset Defaults": "Сброс",
        "Reset time unknown": "Сброс неизвестен",
        "Resetting soon": "Скоро сброс",
        "Runtime copy not built yet. Save & launch from Proxy Overview first.": "Копия ещё не собрана. Сначала сохраните и запустите во вкладке Прокси.",
        "SOCKS5 Port": "Порт SOCKS5",
        "SOCKS5 Ready": "SOCKS5 готов",
        "SOCKS5 handshake OK, invalid probe target host.": "SOCKS5 успешен, неверный тестовый домен.",
        "SOCKS5 port must be between 1 and 65535.": "Порт SOCKS5 должен быть от 1 до 65535.",
        "Save & Quick Launch": "Сохранить и запуск",
        "Settings": "Настройки",
        "Shared quota pool bars & reset countdown (5s auto-refresh)": "Остаток квот и таймер сброса (автообновление каждые 5с)",
        "Show Menu Bar Icon": "Иконка в строке меню",
        "Show Monitor & Billing inside Antigravity": "Показывать панель в Antigravity",
        "Show Sidebar (⌥⌘S)": "Показать панель (⌥⌘S)",
        "Show live context & quota metrics in menu bar (e.g. 188K · 89%)": "Показывать контекст и квоту в строке меню (напр. 188K · 89%)",
        "Show top menu bar icon (minimize to menu bar when window closes)": "Показывать иконку в строке меню (сворачивать при закрытии окна)",
        "Supports LAN CIDRs (e.g. 192.168.0.0/16) and domain suffixes (e.g. *.local) across dylib hook, env vars, and Chromium.": "Поддержка LAN CIDR (192.168.0.0/16) и доменов (*.local) для dylib, переменных среды и Chromium.",
        "Swapping runtime bundle...": "Замена runtime-пакета...",
        "TTFT": "Первый токен",
        "Thinking / Reply": "Мысли / Ответ",
        "Today": "Сегодня",
        "Today's Usage": "За сегодня",
        "Total Tokens": "Всего токенов",
        "Unavailable": "Недоступно",
        "Uninstall": "Удалить",
        "Uninstalled Antigravity in-app dashboard plugin.": "Встроенный плагин Antigravity удалён.",
        "Unknown": "Неизвестно",
        "Unreachable": "Недоступен",
        "Update": "Обновить",
        "Updating bundle info (original icon)...": "Обновление Info.plist (оригинал)...",
        "Updating bundle info...": "Обновление Info.plist...",
        "Usage & Billing": "Расход и счёт",
        "View 3-stage diagnostic details": "Подробности диагностики",
        "View tips": "Подсказки",
        "W": "Ср",
        "Waiting for Antigravity": "Ожидание Antigravity",
        "Writing external proxy config...": "Запись proxy.env...",
        "aux_pane side panel": "aux_pane боковая панель",
        "global full-screen view": "global полный экран",
        "• Automatically notifies running Antigravity Language Server to reload after install/update with zero restart; refreshes run via app-only tools and consume 0 tokens.": "• Автоматически уведомляет Language Server для перезагрузки без перезапуска IDE; обновление данных не тратит токены моделей.",
        "• To avoid self-restart disconnects inside Antigravity, the in-app panel keeps proxy config read-only + live probing; edit ports or bypass rules in Proxy Overview / Settings.": "• Во избежание разрыва связи внутри IDE панель работает в режиме чтения; меняйте порты и NO_PROXY в окне Pilot.",
        "≈ %.1fx $20 Pro/mo": "≈ %.1fx $20 Pro/мес"
    ]
}
