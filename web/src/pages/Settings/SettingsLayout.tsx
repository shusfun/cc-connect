import { useMemo, useState } from 'react';
import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import {
  Archive, ArrowLeft, CircleUserRound, Laptop, Menu, MessageSquare, MonitorCog, Palette,
  RefreshCw, Search, Settings2, X,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { useTranslation } from 'react-i18next';

const groups = [
  { label: 'personal', items: [
    { path: '/settings/general', icon: Settings2, label: 'general', keywords: 'language attachment idle timeout display' },
    { path: '/settings/appearance', icon: Palette, label: 'appearance', keywords: 'theme color dark light' },
    { path: '/settings/account', icon: CircleUserRound, label: 'account', keywords: 'password logout administrator' },
  ] },
  { label: 'connections', items: [
    { path: '/settings/devices', icon: Laptop, label: 'devices', keywords: 'pair Runtime online log' },
    { path: '/settings/feishu', icon: MessageSquare, label: 'feishu', keywords: 'Feishu App ID Secret permission' },
  ] },
  { label: 'system', items: [
    { path: '/settings/updates', icon: RefreshCw, label: 'updates', keywords: 'version release rollback' },
    { path: '/settings/runtime', icon: MonitorCog, label: 'runtime', keywords: 'service config restart log' },
  ] },
  { label: 'archive', items: [
    { path: '/settings/archived', icon: Archive, label: 'archived', keywords: 'restore chat task' },
  ] },
];

export const workspaceReturnPath = (stored: string | null) => {
  const value = stored?.trim() || '';
  if (value === '/' || value === '/scheduled' || value === '/plugins' || value.startsWith('/tasks/')) return value;
  return '/';
};

export default function SettingsLayout() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [query, setQuery] = useState('');
  const [mobileOpen, setMobileOpen] = useState(false);
  const visibleGroups = useMemo(() => {
    const normalized = query.trim().toLowerCase();
    if (!normalized) return groups;
    return groups.map((group) => ({ ...group, items: group.items.filter((item) => `${t(`codex.settings.${item.label}`)} ${t(`codex.settings.${item.label}Keywords`)} ${item.keywords}`.toLowerCase().includes(normalized)) })).filter((group) => group.items.length > 0);
  }, [query, t]);

  const back = () => navigate(workspaceReturnPath(sessionStorage.getItem('cc-connect:last-workspace')));
  return (
    <div className="flex h-dvh min-h-0 overflow-hidden bg-white text-gray-900 dark:bg-[#151513] dark:text-gray-100">
      <aside aria-label={t('codex.settings.navigation')} className={cn('fixed inset-y-0 left-0 z-40 flex h-dvh w-[min(18rem,calc(100vw-2.5rem))] shrink-0 flex-col border-r border-black/[0.08] bg-[#f4f4f1] transition-transform dark:border-white/[0.08] dark:bg-[#20201e] md:static md:w-72 md:translate-x-0', mobileOpen ? 'translate-x-0' : '-translate-x-full')}>
        <div className="shrink-0 px-2 pb-2 pt-4">
          <div className="flex items-center"><button type="button" onClick={back} className="flex h-9 min-w-0 flex-1 items-center gap-2 rounded-md px-2 text-sm text-gray-600 hover:bg-black/[0.05] dark:text-gray-300 dark:hover:bg-white/[0.06]"><ArrowLeft size={16} />{t('codex.settings.back')}</button><button type="button" onClick={() => setMobileOpen(false)} className="grid h-8 w-8 place-items-center rounded-md md:hidden" aria-label={t('codex.settings.closeNavigation')}><X size={16} /></button></div>
          <label className="mt-3 flex h-9 items-center gap-2 rounded-md bg-black/[0.05] px-2 dark:bg-white/[0.06]"><Search size={15} className="text-gray-400" /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={t('codex.settings.search')} className="min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-gray-400" /></label>
        </div>
        <nav className="min-h-0 flex-1 overflow-y-auto px-2 pb-5" aria-label={t('codex.settings.groups')}>
          {visibleGroups.map((group) => <section key={group.label} className="mt-4"><h2 className="mb-1 px-2 text-[11px] font-medium text-gray-400">{t(`codex.settings.${group.label}`)}</h2>{group.items.map(({ path, icon: Icon, label }) => <NavLink key={path} to={path} onClick={() => setMobileOpen(false)} className={({ isActive }) => cn('flex h-9 items-center gap-2 rounded-md px-2 text-sm text-gray-600 hover:bg-black/[0.05] dark:text-gray-300 dark:hover:bg-white/[0.06]', isActive && 'bg-black/[0.07] font-medium text-gray-950 dark:bg-white/[0.09] dark:text-white')}><Icon size={15} />{t(`codex.settings.${label}`)}</NavLink>)}</section>)}
          {visibleGroups.length === 0 && <p className="px-2 py-8 text-center text-xs text-gray-400">{t('codex.settings.noMatch')}</p>}
        </nav>
      </aside>
      {mobileOpen && <button type="button" className="fixed inset-0 z-30 bg-black/35 md:hidden" onClick={() => setMobileOpen(false)} aria-label={t('codex.settings.closeNavigation')} />}
      <main className="relative min-h-0 min-w-0 flex-1 overflow-y-auto">
        <button type="button" onClick={() => setMobileOpen(true)} className="absolute left-3 top-3 grid h-8 w-8 place-items-center rounded-md text-gray-600 hover:bg-black/[0.05] md:hidden dark:text-gray-300" aria-label={t('codex.settings.openNavigation')}><Menu size={17} /></button>
        <div className="mx-auto w-full max-w-4xl px-6 pb-10 pt-14 sm:px-10 md:py-10 lg:py-14"><Outlet /></div>
      </main>
    </div>
  );
}
