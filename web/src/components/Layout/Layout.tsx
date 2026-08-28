import { useState } from 'react';
import { Menu } from 'lucide-react';
import { Outlet, useLocation } from 'react-router-dom';
import Sidebar from './Sidebar';
import { CodexWorkspaceProvider } from '@/pages/Chat/CodexWorkspaceContext';
import { useTranslation } from 'react-i18next';

export default function Layout() {
  const { t } = useTranslation();
  const [mobileNavigationOpen, setMobileNavigationOpen] = useState(false);
  const location = useLocation();
  if (location.pathname !== '/login') sessionStorage.setItem('cc-connect:last-workspace', `${location.pathname}${location.search}`);

  return (
    <CodexWorkspaceProvider>
      <div className="flex h-dvh min-h-0 overflow-hidden bg-white text-gray-900 dark:bg-[#111110] dark:text-gray-100">
        <Sidebar mobileOpen={mobileNavigationOpen} onMobileClose={() => setMobileNavigationOpen(false)} />
        <div className="relative flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden">
          <button type="button" onClick={() => setMobileNavigationOpen(true)} className="absolute left-3 top-2.5 z-20 grid h-8 w-8 place-items-center rounded-md text-gray-600 hover:bg-black/[0.05] md:hidden dark:text-gray-300 dark:hover:bg-white/[0.08]" aria-label={t('codex.openNavigation')}>
            <Menu size={18} />
          </button>
          <main className="flex min-h-0 flex-1 flex-col overflow-hidden">
            <Outlet />
          </main>
        </div>
      </div>
    </CodexWorkspaceProvider>
  );
}
