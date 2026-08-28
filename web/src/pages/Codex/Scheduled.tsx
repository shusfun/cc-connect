import { useCallback, useEffect, useMemo, useState } from 'react';
import { CalendarClock, Loader2, Pause, Play, Plus, Trash2, X } from 'lucide-react';
import {
  createCodexAutomation, deleteCodexAutomation, getCodexCapabilities, listCodexAutomations, listCodexTasks, updateCodexAutomation,
  type CodexAutomation, type CodexAutomationMutation,
} from '@/api/codex';
import { useCodexWorkspace } from '@/pages/Chat/CodexWorkspaceContext';
import { useFeedback } from '@/components/ui';
import { useTranslation } from 'react-i18next';

const messageOf = (cause: unknown) => cause instanceof Error ? cause.message : String(cause);

export default function Scheduled() {
  const { t } = useTranslation();
  const workspace = useCodexWorkspace();
  const { notify, confirm } = useFeedback();
  const devices = useMemo(() => [...new Map(workspace.projects.map((project) => [project.device_id, project])).values()], [workspace.projects]);
  const [deviceID, setDeviceID] = useState('');
  const [items, setItems] = useState<CodexAutomation[]>([]);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [creating, setCreating] = useState(false);
  const [mutationSupported, setMutationSupported] = useState(true);
  const [capabilityLoading, setCapabilityLoading] = useState(false);
  const [targetTasks, setTargetTasks] = useState<Array<{ id: string; label: string }>>([]);
  const [targetTasksError, setTargetTasksError] = useState('');
  const [form, setForm] = useState({ name: '', prompt: '', rrule: '', project_id: '', target_thread_id: '', kind: 'cron' as 'cron' | 'heartbeat' });

  useEffect(() => {
    if (!deviceID && devices.length > 0) setDeviceID(devices.find((device) => device.online)?.device_id || devices[0].device_id);
  }, [deviceID, devices]);

  const load = useCallback(async () => {
    if (!deviceID) return;
    setLoading(true);
    setError('');
    try {
      const response = await listCodexAutomations(deviceID);
      setItems(response.automations || []);
    } catch (cause) {
      setError(messageOf(cause));
      setItems([]);
    } finally {
      setLoading(false);
    }
  }, [deviceID]);

  useEffect(() => { void load(); }, [load]);

  useEffect(() => {
    if (!deviceID) return;
    let cancelled = false;
    setCapabilityLoading(true);
    getCodexCapabilities(deviceID).then((capabilities) => {
      if (!cancelled) setMutationSupported(capabilities.automation_mutation?.supported === true);
    }).catch((cause) => {
      if (!cancelled) {
        setMutationSupported(false);
        setError(messageOf(cause));
      }
    }).finally(() => {
      if (!cancelled) setCapabilityLoading(false);
    });
    return () => { cancelled = true; };
  }, [deviceID]);

  useEffect(() => {
    const projects = workspace.projects.filter((project) => project.device_id === deviceID && project.online && project.available);
    let cancelled = false;
    Promise.all(projects.map(async (project) => {
      const tasks: Array<{ id: string; label: string }> = [];
      const seenCursors = new Set<string>();
      let cursor = '';
      do {
        const page = await listCodexTasks(project.device_id, project.project_id, cursor, 50);
        tasks.push(...(page.sessions || []).map((task) => ({ id: task.id, label: `${task.summary || task.id} - ${project.project_name}` })));
        if (!page.has_more) break;
        if (!page.cursor || seenCursors.has(page.cursor)) throw new Error(t('codex.scheduled.invalidTaskCursor'));
        seenCursors.add(page.cursor);
        cursor = page.cursor;
      } while (true);
      return tasks;
    })).then((values) => {
      if (!cancelled) {
        setTargetTasks(values.flat());
        setTargetTasksError('');
      }
    }).catch((cause) => {
      if (!cancelled) {
        setTargetTasks([]);
        setTargetTasksError(messageOf(cause));
      }
    });
    return () => { cancelled = true; };
  }, [deviceID, t, workspace.projects]);

  const create = async (event: React.FormEvent) => {
    event.preventDefault();
    const mutation: CodexAutomationMutation = {
      name: form.name.trim(), prompt: form.prompt.trim(), rrule: form.rrule.trim(), kind: form.kind,
      status: 'ACTIVE', destination: form.kind === 'heartbeat' ? 'thread' : 'local',
      execution_environment: form.kind === 'cron' ? 'local' : '',
      project_id: form.kind === 'cron' ? form.project_id : '',
      target_thread_id: form.kind === 'heartbeat' ? form.target_thread_id : '',
    };
    setBusy('create');
    try {
      const created = await createCodexAutomation(deviceID, mutation);
      setItems((current) => [...current, created].sort((a, b) => a.name.localeCompare(b.name)));
      setCreating(false);
      setForm({ name: '', prompt: '', rrule: '', project_id: '', target_thread_id: '', kind: 'cron' });
    } catch (cause) {
      notify(messageOf(cause), 'error');
    } finally {
      setBusy('');
    }
  };

  const toggle = async (item: CodexAutomation) => {
    setBusy(item.id);
    try {
      const updated = await updateCodexAutomation(deviceID, item.id, { status: item.status === 'ACTIVE' ? 'PAUSED' : 'ACTIVE' });
      setItems((current) => current.map((value) => value.id === item.id ? updated : value));
    } catch (cause) {
      notify(messageOf(cause), 'error');
    } finally {
      setBusy('');
    }
  };

  const remove = async (item: CodexAutomation) => {
    if (!await confirm({ title: t('codex.scheduled.deleteTitle'), message: t('codex.scheduled.deleteMessage', { name: item.name }), confirmLabel: t('common.delete'), danger: true })) return;
    setBusy(item.id);
    try {
      await deleteCodexAutomation(deviceID, item.id);
      setItems((current) => current.filter((value) => value.id !== item.id));
    } catch (cause) {
      notify(messageOf(cause), 'error');
    } finally {
      setBusy('');
    }
  };

  const projectOptions = workspace.projects.filter((project) => project.device_id === deviceID && project.available);

  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto w-full max-w-4xl px-5 py-8 sm:px-8">
        <header className="mb-7 flex flex-wrap items-center justify-between gap-3">
          <div><h1 className="text-xl font-semibold">{t('codex.scheduled.title')}</h1><p className="mt-1 text-sm text-gray-500">{t('codex.scheduled.subtitle')}</p></div>
          <div className="flex items-center gap-2">
            <select aria-label={t('codex.device')} value={deviceID} onChange={(event) => setDeviceID(event.target.value)} className="h-9 max-w-48 rounded-md border border-black/10 bg-transparent px-2 text-sm dark:border-white/10">
              {devices.map((device) => <option key={device.device_id} value={device.device_id}>{device.device_name}</option>)}
            </select>
            <button type="button" onClick={() => setCreating((value) => !value)} disabled={!deviceID || capabilityLoading || !mutationSupported} className="flex h-9 items-center gap-2 rounded-md bg-gray-950 px-3 text-sm text-white disabled:opacity-40 dark:bg-white dark:text-gray-950">{creating ? <X size={15} /> : <Plus size={15} />}{creating ? t('common.cancel') : t('codex.create')}</button>
          </div>
        </header>

        {!capabilityLoading && deviceID && !mutationSupported && <p role="status" className="mb-5 rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950/30 dark:text-amber-200">{t('codex.scheduled.mutationUnavailable')}</p>}

        {creating && (
          <form onSubmit={create} className="mb-7 space-y-4 border-y border-black/[0.08] py-5 dark:border-white/[0.08]">
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="text-sm"><span className="mb-1.5 block text-gray-500">{t('codex.scheduled.name')}</span><input required value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} className="h-9 w-full rounded-md border border-black/10 bg-transparent px-3 dark:border-white/10" /></label>
              <label className="text-sm"><span className="mb-1.5 block text-gray-500">{t('codex.scheduled.kind')}</span><select value={form.kind} onChange={(event) => setForm({ ...form, kind: event.target.value as 'cron' | 'heartbeat', project_id: '', target_thread_id: '' })} className="h-9 w-full rounded-md border border-black/10 bg-transparent px-3 dark:border-white/10"><option value="cron">{t('codex.scheduled.cron')}</option><option value="heartbeat">{t('codex.scheduled.heartbeat')}</option></select></label>
              <label className="text-sm"><span className="mb-1.5 block text-gray-500">{t('codex.scheduled.rrule')}</span><input required placeholder="Codex RRULE" value={form.rrule} onChange={(event) => setForm({ ...form, rrule: event.target.value })} className="h-9 w-full rounded-md border border-black/10 bg-transparent px-3 font-mono text-xs dark:border-white/10" /></label>
              {form.kind === 'cron' ? <label className="text-sm"><span className="mb-1.5 block text-gray-500">{t('codex.projects')}</span><select value={form.project_id} onChange={(event) => setForm({ ...form, project_id: event.target.value })} className="h-9 w-full rounded-md border border-black/10 bg-transparent px-3 dark:border-white/10"><option value="">{t('codex.scheduled.anyProject')}</option>{projectOptions.map((project) => <option key={project.project_id} value={project.project_id}>{project.project_name}</option>)}</select></label> : <label className="text-sm"><span className="mb-1.5 block text-gray-500">{t('codex.scheduled.targetTask')}</span><select required value={form.target_thread_id} onChange={(event) => setForm({ ...form, target_thread_id: event.target.value })} className="h-9 w-full rounded-md border border-black/10 bg-transparent px-3 dark:border-white/10"><option value="">{t('codex.scheduled.selectTask')}</option>{targetTasks.map((task) => <option key={task.id} value={task.id}>{task.label}</option>)}</select>{targetTasksError && <span role="alert" className="mt-1.5 block text-xs text-red-600 dark:text-red-400">{t('codex.scheduled.targetTasksError', { error: targetTasksError })}</span>}</label>}
            </div>
            <label className="block text-sm"><span className="mb-1.5 block text-gray-500">{t('codex.scheduled.prompt')}</span><textarea required rows={4} value={form.prompt} onChange={(event) => setForm({ ...form, prompt: event.target.value })} className="w-full resize-y rounded-md border border-black/10 bg-transparent px-3 py-2 dark:border-white/10" /></label>
            <button type="submit" disabled={busy === 'create'} className="flex h-9 items-center gap-2 rounded-md bg-blue-600 px-4 text-sm text-white disabled:opacity-50">{busy === 'create' && <Loader2 size={15} className="animate-spin" />}{t('codex.create')}</button>
          </form>
        )}

        {loading && <div className="grid h-40 place-items-center"><Loader2 size={20} className="animate-spin text-gray-400" /></div>}
        {!loading && error && <p role="alert" className="py-10 text-center text-sm text-red-600 dark:text-red-400">{error}</p>}
        {!loading && !error && items.length === 0 && <div className="grid min-h-64 place-items-center text-center"><div><CalendarClock className="mx-auto text-gray-300" size={30} /><p className="mt-3 text-sm text-gray-500">{t('codex.scheduled.empty')}</p></div></div>}
        {!loading && items.length > 0 && <div className="divide-y divide-black/[0.08] border-y border-black/[0.08] dark:divide-white/[0.08] dark:border-white/[0.08]">{items.map((item) => (
          <article key={item.id} className="flex min-w-0 items-start gap-4 py-4">
            <div className="min-w-0 flex-1"><div className="flex items-center gap-2"><h2 className="truncate text-sm font-medium">{item.name}</h2><span className="rounded bg-black/[0.05] px-1.5 py-0.5 text-[10px] text-gray-500 dark:bg-white/[0.07]">{item.status === 'ACTIVE' ? t('codex.scheduled.active') : t('codex.scheduled.paused')}</span></div><p className="mt-1 line-clamp-2 text-sm text-gray-500">{item.prompt}</p><code className="mt-2 block truncate text-[11px] text-gray-400">{item.rrule}</code></div>
            <button type="button" disabled={busy === item.id} onClick={() => void toggle(item)} className="grid h-8 w-8 place-items-center rounded-md text-gray-500 hover:bg-black/[0.05] dark:hover:bg-white/[0.07]" aria-label={item.status === 'ACTIVE' ? t('codex.scheduled.pauseTask', { name: item.name }) : t('codex.scheduled.resumeTask', { name: item.name })}>{item.status === 'ACTIVE' ? <Pause size={15} /> : <Play size={15} />}</button>
            <button type="button" disabled={busy === item.id} onClick={() => void remove(item)} className="grid h-8 w-8 place-items-center rounded-md text-gray-400 hover:bg-red-50 hover:text-red-600 dark:hover:bg-red-950/30" aria-label={t('codex.scheduled.deleteTask', { name: item.name })}><Trash2 size={15} /></button>
          </article>
        ))}</div>}
      </div>
    </div>
  );
}
