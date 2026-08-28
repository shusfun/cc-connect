import { useEffect, useState } from 'react';
import { CheckCircle2, Loader2, Save } from 'lucide-react';
import { getFeishuSettings, updateFeishuSettings } from '@/api/settings';
import { cn } from '@/lib/utils';
import { useTranslation } from 'react-i18next';

const messageOf = (cause: unknown) => cause instanceof Error ? cause.message : String(cause);

export default function FeishuSettings() {
  const { t } = useTranslation();
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [enabled, setEnabled] = useState(false);
  const [appID, setAppID] = useState('');
  const [appSecret, setAppSecret] = useState('');
  const [hasSecret, setHasSecret] = useState(false);
  const [allowFrom, setAllowFrom] = useState('');
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    getFeishuSettings().then((settings) => {
      setEnabled(settings.enabled); setAppID(settings.app_id || ''); setHasSecret(settings.has_app_secret); setAllowFrom(settings.allow_from || '');
    }).catch((cause) => setError(messageOf(cause))).finally(() => setLoading(false));
  }, []);

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    setSaving(true); setMessage(''); setError('');
    try {
      const settings = await updateFeishuSettings({ enabled, app_id: appID, allow_from: allowFrom, ...(appSecret.trim() ? { app_secret: appSecret } : {}) });
      setHasSecret(settings.has_app_secret); setAppSecret('');
      setMessage(t('codex.feishu.saved'));
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setSaving(false);
    }
  };

  if (loading) return <div className="grid h-48 place-items-center"><Loader2 size={20} className="animate-spin text-gray-400" /></div>;
  return (
    <div><h1 className="text-xl font-semibold">{t('codex.settings.feishu')}</h1><p className="mt-1 text-sm text-gray-500">{t('codex.feishu.subtitle')}</p>
      {error && <p role="alert" className="mt-6 rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700 dark:border-red-900 dark:bg-red-950/30 dark:text-red-300">{error}</p>}
      {message && <p role="status" className="mt-6 flex items-center gap-2 rounded-md border border-green-200 bg-green-50 px-4 py-3 text-sm text-green-700 dark:border-green-900 dark:bg-green-950/30 dark:text-green-300"><CheckCircle2 size={15} />{message}</p>}
      <form onSubmit={submit} className="mt-8 max-w-2xl space-y-6">
        <div className="flex items-center justify-between border-y border-black/[0.08] py-4 dark:border-white/[0.08]"><div><div className="text-sm font-medium">{t('codex.feishu.enable')}</div><p className="mt-1 text-xs text-gray-500">{t('codex.feishu.enableHint')}</p></div><button type="button" role="switch" aria-label={t('codex.feishu.enable')} aria-checked={enabled} onClick={() => setEnabled((value) => !value)} className={cn('relative h-6 w-10 rounded-full transition-colors', enabled ? 'bg-blue-500' : 'bg-gray-300 dark:bg-gray-700')}><span className={cn('absolute top-1 h-4 w-4 rounded-full bg-white transition-transform', enabled ? 'left-5' : 'left-1')} /></button></div>
        <label className="block text-sm"><span className="mb-1.5 block font-medium">App ID</span><input disabled={!enabled} required={enabled} value={appID} onChange={(event) => setAppID(event.target.value)} className="h-10 w-full rounded-md border border-black/10 bg-transparent px-3 disabled:opacity-50 dark:border-white/10" /></label>
        <label className="block text-sm"><span className="mb-1.5 block font-medium">App Secret</span><input disabled={!enabled} required={enabled && !hasSecret} type="password" value={appSecret} onChange={(event) => setAppSecret(event.target.value)} placeholder={hasSecret ? t('codex.feishu.secretConfigured') : t('codex.feishu.secretPlaceholder')} autoComplete="new-password" className="h-10 w-full rounded-md border border-black/10 bg-transparent px-3 disabled:opacity-50 dark:border-white/10" /></label>
        <label className="block text-sm"><span className="mb-1.5 block font-medium">{t('codex.feishu.allowedUsers')}</span><input disabled={!enabled} value={allowFrom} onChange={(event) => setAllowFrom(event.target.value)} placeholder={t('codex.feishu.allowedUsersPlaceholder')} className="h-10 w-full rounded-md border border-black/10 bg-transparent px-3 disabled:opacity-50 dark:border-white/10" /><span className="mt-1.5 block text-xs text-gray-500">{t('codex.feishu.allowedUsersHint')}</span></label>
        <button type="submit" disabled={saving} className="flex h-9 items-center gap-2 rounded-md bg-gray-950 px-4 text-sm text-white disabled:opacity-50 dark:bg-white dark:text-gray-950">{saving ? <Loader2 size={15} className="animate-spin" /> : <Save size={15} />}{t('common.save')}</button>
      </form>
    </div>
  );
}
