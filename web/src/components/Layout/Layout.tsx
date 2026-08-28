import { useState } from 'react';
import { Menu } from 'lucide-react';
import { Outlet, useLocation } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import Sidebar from './Sidebar';
import { cn } from '@/lib/utils';

export default function Layout() {
  const [mobileNavigationOpen, setMobileNavigationOpen] = useState(false);
  const location = useLocation();
  const { t } = useTranslation();
  const isChat = location.pathname === '/chat' || location.pathname.startsWith('/chat/');

  return (
    <div
      className={cn(
        'flex h-screen overflow-hidden',
        'bg-[#f7f7f5] text-gray-900 dark:bg-[#111110] dark:text-gray-100',
      )}
    >
      <Sidebar
        mobileOpen={mobileNavigationOpen}
        onMobileClose={() => setMobileNavigationOpen(false)}
      />
      <div className="relative flex min-w-0 flex-1 flex-col overflow-hidden">
        <button
          type="button"
          onClick={() => setMobileNavigationOpen(true)}
          className="absolute left-3 top-3 z-20 flex h-9 w-9 items-center justify-center rounded-md border border-gray-200 bg-white text-gray-600 shadow-sm md:hidden dark:border-white/10 dark:bg-[#1b1b19] dark:text-gray-300"
          aria-label={t('common.openNavigation')}
        >
          <Menu size={17} />
        </button>
        <main className={cn('min-h-0 flex-1', isChat ? 'overflow-hidden' : 'overflow-y-auto')}>
          <div className={cn('mx-auto flex min-h-full w-full flex-col', !isChat && 'max-w-6xl px-4 pb-10 pt-16 sm:px-6 md:py-8')}>
            <Outlet />
          </div>
        </main>
      </div>
    </div>
  );
}
