import { useEffect, useState, useCallback } from 'react';
import { useTranslation } from 'react-i18next';
import { FileCode, RefreshCw, RotateCcw, ChevronDown, ChevronRight } from 'lucide-react';
import { Card, Button, useFeedback } from '@/components/ui';
import { restartSystem, reloadConfig } from '@/api/status';
import api from '@/api/client';
import { useRefresh } from '@/store/refresh';

export default function SystemConfig() {
  const { t } = useTranslation();
  const { generation } = useRefresh();
  const { notify, confirm: askConfirmation } = useFeedback();
  const [content, setContent] = useState('');
  const [format, setFormat] = useState<'toml' | 'json'>('toml');
  const [loading, setLoading] = useState(true);
  const [showRaw, setShowRaw] = useState(false);

  const fetchConfig = useCallback(async () => {
    setLoading(true);
    try {
      const text = await api.raw('/config');
      const trimmed = text.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          const obj = JSON.parse(trimmed);
          setContent(JSON.stringify(obj, null, 2));
          setFormat('json');
        } catch {
          setContent(text);
          setFormat('toml');
        }
      } else {
        setContent(text);
        setFormat('toml');
      }
    } catch {
      setContent('');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void fetchConfig();
  }, [fetchConfig, generation]);

  const handleRestart = async () => {
    if (!await askConfirmation({ title: t('system.restart'), message: t('system.restartConfirm'), confirmLabel: t('system.restart'), danger: true })) return;
    try {
      await restartSystem();
      notify(t('common.success'), 'success');
    } catch (e: any) {
      notify(e.message, 'error');
    }
  };

  const handleReload = async () => {
    if (!await askConfirmation({ title: t('system.reload'), message: t('system.reloadConfirm'), confirmLabel: t('system.reload') })) return;
    try {
      await reloadConfig();
      notify(t('common.success'), 'success');
      void fetchConfig();
    } catch (e: any) {
      notify(e.message, 'error');
    }
  };

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-base font-semibold text-gray-950 dark:text-white">{t('settings.system')}</h2>
        <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t('settings.systemHint')}</p>
      </div>
      {/* Actions */}
      <div className="flex flex-wrap gap-3">
        <Button variant="secondary" onClick={handleReload}><RefreshCw size={16} /> {t('system.reload')}</Button>
        <Button variant="danger" onClick={handleRestart}><RotateCcw size={16} /> {t('system.restart')}</Button>
      </div>

      {/* Raw Config (collapsible) */}
      <Card>
        <button
          type="button"
          onClick={() => setShowRaw(!showRaw)}
          className="flex items-center gap-2 w-full text-left"
        >
          {showRaw ? <ChevronDown size={16} className="text-gray-400" /> : <ChevronRight size={16} className="text-gray-400" />}
          <FileCode size={16} className="text-gray-400" />
          <h3 className="text-sm font-semibold text-gray-900 dark:text-white">{t('system.rawConfig', 'Raw Config')}</h3>
          <span className="text-[10px] font-mono text-gray-400 bg-gray-100 dark:bg-gray-800 px-1.5 py-0.5 rounded uppercase">
            {format}
          </span>
        </button>
        {showRaw && (
          <div className="mt-3">
            {loading ? (
              <div className="text-gray-400 animate-pulse text-sm">Loading...</div>
            ) : (
              <pre className="text-xs text-gray-700 dark:text-gray-300 bg-gray-50 dark:bg-gray-900/50 rounded-lg p-4 overflow-auto max-h-[65vh] font-mono leading-relaxed whitespace-pre">
                {content || t('common.noData')}
              </pre>
            )}
          </div>
        )}
      </Card>
    </div>
  );
}
