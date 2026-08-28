import { useCallback, useEffect, useMemo, useState } from 'react';
import { Blocks, Loader2, Plus, Trash2 } from 'lucide-react';
import { installCodexPlugin, listCodexPlugins, removeCodexPlugin, type CodexPlugin } from '@/api/codex';
import { useCodexWorkspace } from '@/pages/Chat/CodexWorkspaceContext';
import { useFeedback } from '@/components/ui';
import { useTranslation } from 'react-i18next';

const messageOf = (cause: unknown) => cause instanceof Error ? cause.message : String(cause);

export default function Plugins() {
  const { t } = useTranslation();
  const workspace = useCodexWorkspace();
  const { notify, confirm } = useFeedback();
  const devices = useMemo(() => [...new Map(workspace.projects.map((project) => [project.device_id, project])).values()], [workspace.projects]);
  const [deviceID, setDeviceID] = useState('');
  const [plugins, setPlugins] = useState<CodexPlugin[]>([]);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    if (!deviceID && devices.length > 0) setDeviceID(devices.find((device) => device.online)?.device_id || devices[0].device_id);
  }, [deviceID, devices]);

  const load = useCallback(async () => {
    if (!deviceID) return;
    setLoading(true);
    setError('');
    try {
      const response = await listCodexPlugins(deviceID, true);
      setPlugins((response.plugins || []).sort((a, b) => Number(b.installed) - Number(a.installed) || a.name.localeCompare(b.name)));
    } catch (cause) {
      setError(messageOf(cause));
      setPlugins([]);
    } finally {
      setLoading(false);
    }
  }, [deviceID]);

  useEffect(() => { void load(); }, [load]);

  const mutate = async (plugin: CodexPlugin) => {
    if (plugin.installed && !await confirm({ title: t('codex.plugins.removeTitle'), message: t('codex.plugins.removeMessage', { name: plugin.name }), confirmLabel: t('codex.plugins.remove'), danger: true })) return;
    setBusy(plugin.id);
    try {
      if (plugin.installed) await removeCodexPlugin(deviceID, plugin.id); else await installCodexPlugin(deviceID, plugin.id);
      await load();
    } catch (cause) {
      notify(messageOf(cause), 'error');
    } finally {
      setBusy('');
    }
  };

  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto w-full max-w-4xl px-5 py-8 sm:px-8">
        <header className="mb-7 flex flex-wrap items-center justify-between gap-3"><div><h1 className="text-xl font-semibold">{t('codex.plugins.title')}</h1><p className="mt-1 text-sm text-gray-500">{t('codex.plugins.subtitle')}</p></div><select aria-label={t('codex.device')} value={deviceID} onChange={(event) => setDeviceID(event.target.value)} className="h-9 max-w-48 rounded-md border border-black/10 bg-transparent px-2 text-sm dark:border-white/10">{devices.map((device) => <option key={device.device_id} value={device.device_id}>{device.device_name}</option>)}</select></header>
        {loading && <div className="grid h-48 place-items-center"><Loader2 size={20} className="animate-spin text-gray-400" /></div>}
        {!loading && error && <p role="alert" className="py-10 text-center text-sm text-red-600 dark:text-red-400">{error}</p>}
        {!loading && !error && plugins.length === 0 && <div className="grid min-h-64 place-items-center text-center"><div><Blocks className="mx-auto text-gray-300" size={30} /><p className="mt-3 text-sm text-gray-500">{t('codex.plugins.empty')}</p></div></div>}
        {!loading && plugins.length > 0 && <div className="grid gap-px overflow-hidden rounded-lg border border-black/[0.08] bg-black/[0.08] sm:grid-cols-2 dark:border-white/[0.08] dark:bg-white/[0.08]">{plugins.map((plugin) => (
          <article key={plugin.id} className="flex min-h-32 flex-col bg-white p-4 dark:bg-[#171715]">
            <div className="flex items-start gap-3"><Blocks size={18} className="mt-0.5 shrink-0 text-gray-400" /><div className="min-w-0 flex-1"><h2 className="truncate text-sm font-medium">{plugin.name}</h2><p className="mt-0.5 truncate text-xs text-gray-400">{plugin.marketplace}{plugin.version ? ` · ${plugin.version}` : ''}</p></div><button type="button" disabled={busy === plugin.id} onClick={() => void mutate(plugin)} className="grid h-8 w-8 shrink-0 place-items-center rounded-md border border-black/10 text-gray-500 hover:bg-black/[0.04] disabled:opacity-50 dark:border-white/10 dark:hover:bg-white/[0.06]" aria-label={plugin.installed ? t('codex.plugins.removeNamed', { name: plugin.name }) : t('codex.plugins.installNamed', { name: plugin.name })}>{busy === plugin.id ? <Loader2 size={14} className="animate-spin" /> : plugin.installed ? <Trash2 size={14} /> : <Plus size={14} />}</button></div>
            <div className="mt-auto flex gap-2 pt-4 text-[10px] text-gray-400"><span>{plugin.installed ? t('codex.plugins.installed') : t('codex.plugins.available')}</span>{plugin.enabled && <span>{t('codex.plugins.enabled')}</span>}{plugin.auth_policy && <span>{plugin.auth_policy}</span>}</div>
          </article>
        ))}</div>}
      </div>
    </div>
  );
}
