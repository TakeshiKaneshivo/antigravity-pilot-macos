export type ResolvedLang = 'zh-Hans' | 'zh-Hant' | 'en' | 'ru';

export function resolveLanguage(serverResolved?: string): ResolvedLang {
  if (
    serverResolved === 'zh-Hans' ||
    serverResolved === 'zh-Hant' ||
    serverResolved === 'en' ||
    serverResolved === 'ru'
  ) {
    return serverResolved;
  }

  const candidates =
    Array.isArray(navigator.languages) && navigator.languages.length > 0
      ? navigator.languages
      : [navigator.language || 'en'];

  for (const raw of candidates) {
    const lang = (raw || '').toLowerCase();
    if (
      lang.startsWith('zh-hant') ||
      lang.startsWith('zh_hant') ||
      lang === 'zh-tw' ||
      lang === 'zh-hk' ||
      lang === 'zh-mo' ||
      lang.startsWith('zh-tw-') ||
      lang.startsWith('zh-hk-') ||
      lang.startsWith('zh-mo-') ||
      lang.startsWith('zh_tw') ||
      lang.startsWith('zh_hk') ||
      lang.startsWith('zh_mo')
    ) {
      return 'zh-Hant';
    }
    if (lang === 'zh' || lang.startsWith('zh-') || lang.startsWith('zh_')) {
      return 'zh-Hans';
    }
    if (lang === 'ru' || lang.startsWith('ru-') || lang.startsWith('ru_')) {
      return 'ru';
    }
    if (lang === 'en' || lang.startsWith('en-') || lang.startsWith('en_')) {
      return 'en';
    }
  }
  return 'en';
}

export function getMonthNames(lang: ResolvedLang): string[] {
  if (lang === 'ru') {
    return ['Янв', 'Фев', 'Мар', 'Апр', 'Май', 'Июн', 'Июл', 'Авг', 'Сен', 'Окт', 'Ноя', 'Дек'];
  }
  if (lang === 'en') {
    return ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  }
  return ['1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月', '10月', '11月', '12月'];
}

export function t(zhHans: string, en: string, lang: ResolvedLang): string {
  if (lang === 'zh-Hans') return zhHans;
  if (lang === 'zh-Hant') return zhHantDict[en] ?? zhHans;
  if (lang === 'ru') return ruDict[en] ?? en;
  return en;
}

export function t4(
  zhHans: string,
  zhHant: string,
  en: string,
  ru: string,
  lang: ResolvedLang
): string {
  if (lang === 'zh-Hans') return zhHans;
  if (lang === 'zh-Hant') return zhHant;
  if (lang === 'ru') return ru;
  return en;
}

const zhHantDict: Record<string, string> = {
  'Today': '今日',
  '7 Days': '近 7 天',
  '30 Days': '近 30 天',
  'All': '全部',
  'Expand panel': '展開面板',
  'Collapse panel': '收起面板',
  'Tool call returned an error. Click Refresh to retry.': '工具呼叫傳回異常，請點擊重新整理重試。',
  'Server returned an error while refreshing data.': '重新整理資料時伺服器傳回錯誤。',
  'Waiting for Antigravity': '等待 Antigravity 執行',
  'Live Monitor': '即時監控',
  'Usage & Billing': '用量與帳單',
  'Expand All': '全部展開',
  'Collapse All': '全部收起',
  'Refreshing…': '重新整理中…',
  'Refresh': '重新整理',
  'Proxy Health Monitor (Read-only)': '代理健康監控（唯讀）',
  'Synced from Antigravity Pilot config': '同步自 Antigravity Pilot 設定',
  'No local config.json found; probing with defaults': '未偵測到本機 config.json，使用預設設定探測',
  'Probing…': '探測中…',
  'Re-test': '三階重測',
  'Env / Chromium Proxy': 'Env / Chromium 代理',
  '3. Net': '3. 外網',
  'Not probed': '未探測',
  '▾ Hide NO_PROXY Bypass Rules': '▾ 隱藏 NO_PROXY 繞過規則',
  '▸ Show NO_PROXY Bypass Rules': '▸ 查看 NO_PROXY 繞過規則',
  'Active Session Context': '目前工作階段上下文',
  'Auto (Latest)': '自動（最新工作階段）',
  'Offline': '未連線',
  'Not Connected to Local Language Server': '暫未連線到本機 Language Server',
  'Ensure Antigravity has finished initializing; the dashboard discovers sessions & quotas automatically.': '請確認 Antigravity 已完成初始化；應用內看板會自動探索目前工作階段與配額。',
  'No model usage recorded in the selected session.': '目前選定工作階段暫無模型呼叫紀錄。',
  'Cached': '快取命中',
  'New In': '新增輸入',
  'Output': '輸出',
  'Cache Hit Rate': '快取命中率',
  'TTFT': '首字延遲 (TTFT)',
  'Output Speed': '輸出速度',
  'Thinking / Reply': '思考 / 回覆',
  'No model quota information available yet.': '暫未取得模型配額資訊。',
  'Loading local session usage archives…': '正在載入本機工作階段用量歸檔…',
  'Loading live monitor…': '正在載入即時監控…',
  'Total Tokens': '總消耗 Token',
  'Model Calls': '模型呼叫次數',
  'Est. API Cost': '估算 API 帳單',
  '1-Year Token Heatmap': '近一年 Token 活躍熱力圖',
  'Click a cell for day details': '點擊方格查看單日明細',
  'M': '一',
  'W': '三',
  'F': '五',
  'Less': '低',
  'More': '高',
  'By local calendar day': '按本機自然日統計',
  '14-Day Token Trend': '近 14 日 Token 趨勢',
  'Hover or click a bar for details': '懸停或點擊長條查看當日詳情',
  'Estimated via API pricing, not actual billing': '參考 API 定價估算，非實際扣費',
  'No usage data in the last 14 days': '暫無近 14 日用量紀錄',
  'No model usage recorded in this period.': '所選週期暫無模型呼叫紀錄。',
  'No session usage recorded in this period.': '所選週期暫無工作階段呼叫紀錄。',
  'Local monitor refresh error: ': '本機監控重新整理異常：',
  'Context Breakdown': '上下文構成',
  'Session Cost': '本工作階段費用',
  'By Model': '按模型',
  'By Project': '按專案',
  'By Session': '按工作階段',
  'Est. via public API pricing': '參考 API 公開單價',
  'Free tier · API reference': 'Free 檔 · 參考 API 單價',
  'Compact': '壓縮',
  'Model': '模型',
  'Context': '上下文',
  'Cost': '費用',
  'Subagent': '子代理',
};

const ruDict: Record<string, string> = {
  'Today': 'Сегодня',
  '7 Days': '7 дн.',
  '30 Days': '30 дн.',
  'All': 'Все',
  'Expand panel': 'Развернуть панель',
  'Collapse panel': 'Свернуть панель',
  'Tool call returned an error. Click Refresh to retry.': 'Ошибка вызова инструмента. Нажмите Обновить.',
  'Server returned an error while refreshing data.': 'Сервер вернул ошибку при обновлении данных.',
  'Waiting for Antigravity': 'Ожидание Antigravity',
  'Live Monitor': 'Монитор',
  'Usage & Billing': 'Расход и счёт',
  'Expand All': 'Развернуть все',
  'Collapse All': 'Свернуть все',
  'Refreshing…': 'Обновление…',
  'Refresh': 'Обновить',
  'Proxy Health Monitor (Read-only)': 'Монитор прокси (только чтение)',
  'Synced from Antigravity Pilot config': 'Синхронизировано с Antigravity Pilot',
  'No local config.json found; probing with defaults': 'config.json не найден; проверка со значениями по умолчанию',
  'Probing…': 'Проверка…',
  'Re-test': 'Тест',
  'Env / Chromium Proxy': 'Прокси Env / Chromium',
  '3. Net': '3. Сеть',
  'Not probed': 'Не провер.',
  '▾ Hide NO_PROXY Bypass Rules': '▾ Скрыть правила NO_PROXY',
  '▸ Show NO_PROXY Bypass Rules': '▸ Показать правила NO_PROXY',
  'Active Session Context': 'Контекст активной сессии',
  'Auto (Latest)': 'Авто (последняя)',
  'Offline': 'Не в сети',
  'Not Connected to Local Language Server': 'Нет связи с локальным Language Server',
  'Ensure Antigravity has finished initializing; the dashboard discovers sessions & quotas automatically.': 'Убедитесь, что Antigravity запущен; панель найдёт сессии и квоты автоматически.',
  'No model usage recorded in the selected session.': 'В выбранной сессии нет вызовов моделей.',
  'Cached': 'Кэш',
  'New In': 'Вход',
  'Output': 'Выход',
  'Cache Hit Rate': 'Кэш-хит',
  'TTFT': 'Первый токен',
  'Output Speed': 'Скорость',
  'Thinking / Reply': 'Мысли / Ответ',
  'No model quota information available yet.': 'Данные о квотах моделей пока недоступны.',
  'Loading local session usage archives…': 'Загрузка локальных архивов сессий…',
  'Loading live monitor…': 'Загрузка живого монитора…',
  'Total Tokens': 'Всего токенов',
  'Model Calls': 'Вызовы API',
  'Est. API Cost': 'Оценка API',
  '1-Year Token Heatmap': 'Активность токенов за год',
  'Click a cell for day details': 'Нажмите ячейку для деталей',
  'M': 'Пн',
  'W': 'Ср',
  'F': 'Пт',
  'Less': 'Меньше',
  'More': 'Больше',
  'By local calendar day': 'По локальным суткам',
  '14-Day Token Trend': 'Тренд токенов за 14 дней',
  'Hover or click a bar for details': 'Наведите или нажмите столбец',
  'Estimated via API pricing, not actual billing': 'Оценка по тарифам API, не реальный счёт',
  'No usage data in the last 14 days': 'Нет данных за последние 14 дней',
  'No model usage recorded in this period.': 'За выбранный период нет вызовов моделей.',
  'No session usage recorded in this period.': 'За выбранный период нет вызовов в сессиях.',
  'Local monitor refresh error: ': 'Ошибка обновления монитора: ',
  'Context Breakdown': 'Состав контекста',
  'Session Cost': 'Цена сессии',
  'By Model': 'Модели',
  'By Project': 'Проекты',
  'By Session': 'Сессии',
  'Est. via public API pricing': 'Оценка по тарифам API',
  'Free tier · API reference': 'Free · оценка по API',
  'Compact': 'Сжатие',
  'Model': 'Модель',
  'Context': 'Контекст',
  'Cost': 'Цена',
  'Subagent': 'Субагент',
};
