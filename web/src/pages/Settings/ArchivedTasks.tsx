import { useEffect, useMemo, useState } from 'react';
import { ArchiveRestore, Eye, Loader2 } from 'lucide-react';
import { listArchivedCodexTasks, listCodexProjects, restoreArchivedCodexTask, type CodexProject, type CodexTask } from '@/api/codex';
import { useFeedback } from '@/components/ui';
import { useTranslation } from 'react-i18next';
import { useNavigate } from 'react-router-dom';

type ArchivedItem = { device: CodexProject; task: CodexTask };
const messageOf = (cause: unknown) => cause instanceof Error ? cause.message : String(cause);

export default function ArchivedTasks() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { notify } = useFeedback();
  const [items, setItems] = useState<ArchivedItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');

  const load = async () => {
    setLoading(true);
    setError('');
    try {
      const catalog = await listCodexProjects();
      const devices = [...new Map((catalog.projects || []).map((project) => [project.device_id, project])).values()];
      const pages = await Promise.all(devices.filter((device) => device.online).map(async (device) => ({ device, page: await listArchivedCodexTasks(device.device_id, 50) })));
      setItems(pages.flatMap(({ device, page }) => (page.sessions || []).map((task) => ({ device, task }))));
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { void load(); }, []);
  const sorted = useMemo(() => [...items].sort((a, b) => (b.task.modified_at || '').localeCompare(a.task.modified_at || '')), [items]);

  const restore = async (item: ArchivedItem) => {
    setBusy(item.task.id);
    try {
      await restoreArchivedCodexTask(item.device.device_id, item.task.id, item.task.host_id);
      setItems((current) => current.filter((value) => value.task.id !== item.task.id || value.device.device_id !== item.device.device_id));
      notify(t('codex.archived.restored'), 'success');
    } catch (cause) {
      notify(messageOf(cause), 'error');
    } finally {
      setBusy('');
    }
  };

  return (
    <div><h1 className="text-xl font-semibold">{t('codex.archived.title')}</h1><p className="mt-1 text-sm text-gray-500">{t('codex.archived.subtitle')}</p>
      {loading && <div className="grid h-48 place-items-center"><Loader2 size={20} className="animate-spin text-gray-400" /></div>}
      {!loading && error && <p role="alert" className="py-10 text-sm text-red-600 dark:text-red-400">{error}</p>}
      {!loading && !error && sorted.length === 0 && <p className="py-12 text-center text-sm text-gray-400">{t('codex.archived.empty')}</p>}
      {!loading && sorted.length > 0 && <div className="mt-7 divide-y divide-black/[0.08] border-y border-black/[0.08] dark:divide-white/[0.08] dark:border-white/[0.08]">{sorted.map((item) => (
        <article key={`${item.device.device_id}:${item.task.host_id || ''}:${item.task.id}`} className="flex min-w-0 items-center gap-2 py-4"><div className="min-w-0 flex-1"><h2 className="truncate text-sm font-medium">{item.task.summary || item.task.id}</h2><p className="mt-1 truncate text-xs text-gray-400">{item.task.project_name || item.task.project_id} · {item.device.device_name}</p></div><button type="button" onClick={() => navigate(`/tasks/${encodeURIComponent(item.device.device_id)}/${encodeURIComponent(item.task.project_id)}/${encodeURIComponent(item.task.id)}`)} className="grid h-8 w-8 place-items-center rounded-md border border-black/10 hover:bg-black/[0.04] dark:border-white/10 dark:hover:bg-white/[0.06]" aria-label={t('codex.archived.viewNamed', { name: item.task.summary || item.task.id })}><Eye size={14} /></button><button type="button" disabled={busy === item.task.id} onClick={() => void restore(item)} className="flex h-8 items-center gap-2 rounded-md border border-black/10 px-3 text-xs hover:bg-black/[0.04] disabled:opacity-50 dark:border-white/10 dark:hover:bg-white/[0.06]"><ArchiveRestore size={14} />{t('codex.archived.restore')}</button></article>
      ))}</div>}
    </div>
  );
}
