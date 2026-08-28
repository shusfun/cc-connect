import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import en from './locales/en.json';
import zh from './locales/zh.json';
import zhTW from './locales/zh-TW.json';
import ja from './locales/ja.json';
import es from './locales/es.json';
import ko from './locales/ko.json';
import ru from './locales/ru.json';
import codex from './codex';

const saved = localStorage.getItem('cc_lang') || navigator.language.split('-')[0] || 'en';

i18n.use(initReactI18next).init({
  resources: {
    en: { translation: { ...en, codex: codex.en } },
    zh: { translation: { ...zh, codex: codex.zh } },
    'zh-TW': { translation: { ...zhTW, codex: codex['zh-TW'] } },
    ja: { translation: { ...ja, codex: codex.ja } },
    es: { translation: { ...es, codex: codex.es } },
    ko: { translation: { ...ko, codex: codex.ko } },
    ru: { translation: { ...ru, codex: codex.ru } },
  },
  lng: saved,
  fallbackLng: 'en',
  interpolation: { escapeValue: false },
});

export default i18n;
