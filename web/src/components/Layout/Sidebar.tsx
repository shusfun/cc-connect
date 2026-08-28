import { NavLink } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import {
  LayoutDashboard,
  FolderKanban,
  MessageSquare,
  MessagesSquare,
  Clock,
  Settings,
  ChevronLeft,
  ChevronRight,
  Plug,
  Puzzle,
  ServerCog,
  Github,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { useState } from 'react';

const navGroups = [
  { label: 'nav.workspace', items: [
    { key: 'dashboard', path: '/', icon: LayoutDashboard },
    { key: 'chat', path: '/chat', icon: MessageSquare },
    { key: 'projects', path: '/projects', icon: FolderKanban },
    { key: 'platformSessions', path: '/platform-sessions', icon: MessagesSquare },
  ] },
  { label: 'nav.manage', items: [
    { key: 'providers', path: '/providers', icon: Plug },
    { key: 'skills', path: '/skills', icon: Puzzle },
    { key: 'cron', path: '/cron', icon: Clock },
    { key: 'operations', path: '/operations', icon: ServerCog },
  ] },
];

type SidebarProps = {
  mobileOpen: boolean;
  onMobileClose: () => void;
};

export default function Sidebar({ mobileOpen, onMobileClose }: SidebarProps) {
  const { t } = useTranslation();
  const [collapsed, setCollapsed] = useState(false);

  return (
    <>
      <aside
        aria-label={t('common.navigation')}
        className={cn(
          'fixed inset-y-0 left-0 z-40 flex h-screen w-60 flex-col border-r transition-[transform,width] duration-200',
          'border-gray-200 bg-[#efefec]',
          'dark:border-white/[0.08] dark:bg-[#171715]',
          mobileOpen ? 'translate-x-0' : '-translate-x-full',
          'md:static md:z-auto md:translate-x-0',
          collapsed ? 'md:w-14' : 'md:w-60',
        )}
      >
      {/* Brand */}
      <div
        className={cn(
          'flex h-14 shrink-0 items-center px-3',
          collapsed ? 'justify-center' : 'gap-0',
        )}
      >
        {collapsed ? (
          <span className="text-sm font-semibold text-gray-900 dark:text-white">
            CC
          </span>
        ) : (
          <span className="text-sm font-semibold text-gray-900 dark:text-white">
            CC-Connect
          </span>
        )}
      </div>

      {/* Navigation */}
      <nav className="flex-1 space-y-5 overflow-y-auto px-2 py-2">
        {navGroups.map((group) => <div key={group.label}>
          <div className={cn('mb-1 px-2 text-[11px] font-medium text-gray-400', collapsed && 'md:hidden')}>{t(group.label)}</div>
          <div className="space-y-0.5">{group.items.map(({ key, path, icon: Icon }) => (
          <NavLink
            key={key}
            to={path}
            end={path === '/'}
            onClick={onMobileClose}
            className={({ isActive }) =>
              cn(
                'flex h-9 items-center gap-3 rounded-md px-2.5 text-sm transition-colors',
                isActive
                  ? 'bg-white text-gray-950 shadow-sm dark:bg-white/[0.08] dark:text-white'
                  : 'text-gray-600 hover:bg-black/[0.04] hover:text-gray-950 dark:text-gray-400 dark:hover:bg-white/[0.05] dark:hover:text-white',
              )
            }
          >
            <Icon size={18} className="shrink-0" />
            <span className={collapsed ? 'md:hidden' : undefined}>{t(`nav.${key}`)}</span>
          </NavLink>
          ))}</div>
        </div>)}
      </nav>

      <div className="space-y-0.5 border-t border-gray-200 p-2 dark:border-white/[0.08]">
        <NavLink
          to="/settings"
          onClick={onMobileClose}
          className={({ isActive }) => cn('flex h-9 items-center gap-3 rounded-md px-2.5 text-sm transition-colors', isActive ? 'bg-white text-gray-950 shadow-sm dark:bg-white/[0.08] dark:text-white' : 'text-gray-600 hover:bg-black/[0.04] dark:text-gray-400 dark:hover:bg-white/[0.05]', collapsed && 'md:justify-center')}
        >
          <Settings size={17} className="shrink-0" />
          <span className={collapsed ? 'md:hidden' : undefined}>{t('nav.settings')}</span>
        </NavLink>
        <a href="https://github.com/shusfun/cc-connect" target="_blank" rel="noreferrer" className={cn('flex h-9 items-center gap-3 rounded-md px-2.5 text-sm text-gray-500 hover:bg-black/[0.04] dark:text-gray-500 dark:hover:bg-white/[0.05]', collapsed && 'md:justify-center')}>
          <Github size={17} className="shrink-0" />
          <span className={collapsed ? 'md:hidden' : undefined}>GitHub</span>
        </a>
        <button
          type="button"
          onClick={() => setCollapsed(!collapsed)}
          className={cn(
            'hidden h-8 w-full items-center justify-center rounded-md text-gray-400 transition-colors hover:bg-black/[0.04] md:flex dark:hover:bg-white/[0.05]',
          )}
        >
          {collapsed ? <ChevronRight size={18} /> : <ChevronLeft size={18} />}
        </button>
      </div>
      </aside>
      {mobileOpen && (
        <button
          type="button"
          className="fixed inset-0 z-30 bg-black/40 md:hidden"
          onClick={onMobileClose}
          aria-label={t('common.close')}
        />
      )}
    </>
  );
}
