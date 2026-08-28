import { useCallback, useEffect, useState } from 'react';
import { Bell, Check, Loader2 } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { listCodexNotifications, markCodexNotificationsRead, type CodexNotification } from '@/api/codex';
import { useTranslation } from 'react-i18next';

const timeLabel = (value: string, locale: string) => {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : new Intl.DateTimeFormat(locale, { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }).format(date);
};

const notificationTitle = (translate: (key: string) => string, type: string) => {
  const knownTypes = new Set([
    'runtime_connected', 'runtime_disconnected', 'device_paired', 'device_revoked',
    'task_completed', 'task_failed', 'deploy_completed', 'deploy_failed',
    'runtime_update_completed', 'runtime_update_failed',
  ]);
  return translate(`codex.notifications.events.${knownTypes.has(type) ? type : 'default'}`);
};

export default function NotificationPopover() {
  const { t, i18n } = useTranslation();
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const [items, setItems] = useState<CodexNotification[]>([]);
  const [unread, setUnread] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      const page = await listCodexNotifications(0, 30);
      setItems(page.items || []);
      setUnread(page.unread || 0);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);
  useEffect(() => { if (open) void load(); }, [load, open]);

  const readAll = async () => {
    const latest = Math.max(0, ...items.map((item) => item.id));
    if (!latest) return;
    try {
      await markCodexNotificationsRead(latest);
      setItems((current) => current.map((item) => ({ ...item, read: true })));
      setUnread(0);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    }
  };

  return (
    <div className="relative">
      <button type="button" onClick={() => setOpen((value) => !value)} className="relative grid h-8 w-8 place-items-center rounded-md text-gray-500 hover:bg-black/[0.06] dark:text-gray-400 dark:hover:bg-white/[0.07]" aria-label={t('codex.notifications.title')} aria-expanded={open}>
        <Bell size={16} />
        {unread > 0 && <span className="absolute right-0.5 top-0.5 min-w-4 rounded-full bg-red-500 px-1 text-center text-[9px] leading-4 text-white">{unread > 99 ? '99+' : unread}</span>}
      </button>
      {open && (
        <div className="absolute left-0 top-10 z-50 w-[min(22rem,calc(100vw-2rem))] overflow-hidden rounded-lg border border-black/10 bg-white shadow-xl dark:border-white/10 dark:bg-[#20201e]">
          <div className="flex h-11 items-center justify-between border-b border-black/[0.08] px-3 dark:border-white/[0.08]">
            <span className="text-sm font-semibold">{t('codex.notifications.title')}</span>
            <button type="button" onClick={() => void readAll()} disabled={unread === 0} className="flex h-7 items-center gap-1 rounded-md px-2 text-xs text-gray-500 hover:bg-black/[0.05] disabled:opacity-40 dark:hover:bg-white/[0.07]"><Check size={13} />{t('codex.notifications.readAll')}</button>
          </div>
          <div className="max-h-96 overflow-y-auto p-1.5">
            {loading && <div className="grid h-24 place-items-center"><Loader2 size={17} className="animate-spin text-gray-400" /></div>}
            {!loading && error && <p role="alert" className="px-3 py-6 text-center text-xs text-red-600 dark:text-red-400">{error}</p>}
            {!loading && !error && items.length === 0 && <p className="px-3 py-8 text-center text-xs text-gray-400">{t('codex.notifications.empty')}</p>}
            {!loading && items.map((item) => (
              <button key={item.id} type="button" disabled={!item.href} onClick={() => { if (item.href) navigate(item.href); setOpen(false); }} className="relative flex w-full flex-col rounded-md px-3 py-2 text-left hover:bg-black/[0.05] disabled:cursor-default dark:hover:bg-white/[0.07]">
                {!item.read && <span className="absolute left-1 top-3 h-1.5 w-1.5 rounded-full bg-blue-500" />}
                <span className="text-sm">{notificationTitle(t, item.type)}</span>
                <span className="mt-0.5 text-[11px] text-gray-400">{timeLabel(item.occurred_at, i18n.language)}</span>
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
