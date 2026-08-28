import { NavLink, Outlet } from 'react-router-dom';
import { CircleUserRound, MonitorCog, Palette, SlidersHorizontal } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { cn } from '@/lib/utils';

const sections = [
  { key: 'general', path: '/settings/general', icon: SlidersHorizontal },
  { key: 'appearance', path: '/settings/appearance', icon: Palette },
  { key: 'system', path: '/settings/system', icon: MonitorCog },
  { key: 'account', path: '/settings/account', icon: CircleUserRound },
];

export default function SettingsLayout() {
  const { t } = useTranslation();

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="mb-6">
        <h1 className="text-xl font-semibold text-gray-950 dark:text-white">{t('nav.settings')}</h1>
      </header>
      <div className="grid min-h-0 flex-1 gap-8 md:grid-cols-[12rem_minmax(0,1fr)]">
        <nav aria-label={t('settings.sections')} className="flex gap-1 overflow-x-auto md:flex-col">
          {sections.map(({ key, path, icon: Icon }) => (
            <NavLink
              key={key}
              to={path}
              className={({ isActive }) => cn(
                'flex h-9 shrink-0 items-center gap-2 rounded-md px-3 text-sm transition-colors',
                isActive
                  ? 'bg-gray-200/80 font-medium text-gray-950 dark:bg-white/[0.08] dark:text-white'
                  : 'text-gray-500 hover:bg-gray-100 hover:text-gray-900 dark:text-gray-400 dark:hover:bg-white/[0.05] dark:hover:text-white',
              )}
            >
              <Icon size={16} />
              {t(`settings.${key}`)}
            </NavLink>
          ))}
        </nav>
        <section className="min-w-0 max-w-3xl pb-8">
          <Outlet />
        </section>
      </div>
    </div>
  );
}
