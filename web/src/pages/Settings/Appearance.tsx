import { Languages, Monitor, Moon, Sun } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { useThemeStore } from '@/store/theme';
import { cn } from '@/lib/utils';

const languages = [
  { code: 'en', label: 'English' },
  { code: 'zh', label: '简体中文' },
  { code: 'zh-TW', label: '繁體中文' },
  { code: 'ja', label: '日本語' },
  { code: 'ko', label: '한국어' },
  { code: 'es', label: 'Español' },
  { code: 'ru', label: 'Русский' },
];

const themes = [
  { value: 'light' as const, key: 'light', icon: Sun },
  { value: 'dark' as const, key: 'dark', icon: Moon },
  { value: 'system' as const, key: 'systemTheme', icon: Monitor },
];

export default function Appearance() {
  const { t, i18n } = useTranslation();
  const { theme, setTheme } = useThemeStore();

  const changeLanguage = (code: string) => {
    void i18n.changeLanguage(code);
    localStorage.setItem('cc_lang', code);
  };

  return (
    <div className="space-y-8">
      <div>
        <h2 className="text-base font-semibold text-gray-950 dark:text-white">{t('settings.appearance')}</h2>
        <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t('settings.appearanceHint')}</p>
      </div>

      <section className="border-t border-gray-200 pt-5 dark:border-white/[0.08]">
        <div className="mb-3 flex items-center gap-2 text-sm font-medium"><Monitor size={16} />{t('common.theme')}</div>
        <div className="inline-flex rounded-lg border border-gray-200 bg-gray-100 p-1 dark:border-white/[0.08] dark:bg-black/20">
          {themes.map(({ value, key, icon: Icon }) => (
            <button key={value} type="button" onClick={() => setTheme(value)} aria-pressed={theme === value} className={cn('flex h-8 items-center gap-2 rounded-md px-3 text-sm transition-colors', theme === value ? 'bg-white text-gray-950 shadow-sm dark:bg-white/[0.12] dark:text-white' : 'text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-white')}>
              <Icon size={15} />{t(`settings.${key}`)}
            </button>
          ))}
        </div>
      </section>

      <section className="border-t border-gray-200 pt-5 dark:border-white/[0.08]">
        <label htmlFor="settings-language" className="mb-2 flex items-center gap-2 text-sm font-medium"><Languages size={16} />{t('settings.language')}</label>
        <select id="settings-language" value={i18n.language} onChange={(event) => changeLanguage(event.target.value)} className="h-9 w-full max-w-xs rounded-md border border-gray-300 bg-white px-3 text-sm outline-none focus:border-gray-500 focus:ring-2 focus:ring-gray-300/50 dark:border-white/[0.12] dark:bg-[#1a1a18] dark:focus:border-white/30">
          {languages.map((language) => <option key={language.code} value={language.code}>{language.label}</option>)}
        </select>
      </section>
    </div>
  );
}
