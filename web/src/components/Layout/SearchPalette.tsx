import { useEffect, useRef, useState } from 'react';
import { Loader2, Search, X } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { searchCodexTasks, type CodexOfflineDevice, type CodexSearchResult } from '@/api/codex';
import { useTranslation } from 'react-i18next';

type SearchPaletteProps = { open: boolean; onClose: () => void };

const taskHref = (result: CodexSearchResult) => {
  const task = result.task;
  return `/tasks/${encodeURIComponent(result.device_id)}/${encodeURIComponent(task.project_id)}/${encodeURIComponent(task.id)}`;
};

export default function SearchPalette({ open, onClose }: SearchPaletteProps) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const input = useRef<HTMLInputElement>(null);
  const sequence = useRef(0);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<CodexSearchResult[]>([]);
  const [offline, setOffline] = useState<CodexOfflineDevice[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [activeIndex, setActiveIndex] = useState(0);

  useEffect(() => {
    if (!open) return;
    setTimeout(() => input.current?.focus(), 0);
  }, [open]);

  useEffect(() => {
    if (!open || query.trim().length < 2) {
      setResults([]);
      setOffline([]);
      setLoading(false);
      setError('');
      return;
    }
    const current = ++sequence.current;
    const timer = setTimeout(() => {
      setLoading(true);
      setError('');
      searchCodexTasks(query.trim(), 40)
        .then((response) => {
          if (sequence.current === current) setResults(response.results || []);
          if (sequence.current === current) setOffline(response.offline_devices || []);
        })
        .catch((cause) => {
          if (sequence.current === current) setError(cause instanceof Error ? cause.message : String(cause));
        })
        .finally(() => {
          if (sequence.current === current) setLoading(false);
        });
    }, 180);
    return () => clearTimeout(timer);
  }, [open, query]);

  useEffect(() => { setActiveIndex(0); }, [results]);

  if (!open) return null;
  return (
    <div className="fixed inset-0 z-[70] bg-black/35 px-3 pt-[12vh] backdrop-blur-[1px]" onMouseDown={onClose}>
      <section role="dialog" aria-modal="true" aria-label={t('codex.search.title')} onMouseDown={(event) => event.stopPropagation()} className="mx-auto max-h-[70vh] w-full max-w-2xl overflow-hidden rounded-lg border border-black/10 bg-white shadow-2xl dark:border-white/10 dark:bg-[#20201e]">
        <div className="flex h-12 items-center gap-3 border-b border-black/[0.08] px-4 dark:border-white/[0.08]">
          {loading ? <Loader2 size={17} className="animate-spin text-gray-400" /> : <Search size={17} className="text-gray-400" />}
          <input ref={input} role="combobox" aria-label={t('codex.search.placeholder')} aria-controls="codex-search-results" aria-expanded={results.length > 0} aria-activedescendant={results[activeIndex] ? `codex-search-result-${activeIndex}` : undefined} value={query} onChange={(event) => setQuery(event.target.value)} onKeyDown={(event) => {
            if (event.key === 'Escape') onClose();
            if (event.key === 'ArrowDown' && results.length > 0) { event.preventDefault(); setActiveIndex((value) => (value + 1) % results.length); }
            if (event.key === 'ArrowUp' && results.length > 0) { event.preventDefault(); setActiveIndex((value) => (value - 1 + results.length) % results.length); }
            if (event.key === 'Enter' && results[activeIndex]) { event.preventDefault(); navigate(taskHref(results[activeIndex])); onClose(); }
          }} placeholder={t('codex.search.placeholder')} className="min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-gray-400" />
          <button type="button" onClick={onClose} className="grid h-7 w-7 place-items-center rounded-md text-gray-400 hover:bg-black/[0.06] dark:hover:bg-white/[0.08]" aria-label={t('codex.search.close')}><X size={16} /></button>
        </div>
        <div id="codex-search-results" role="listbox" className="max-h-[calc(70vh-3rem)] overflow-y-auto p-2">
          {error && <p role="alert" className="px-3 py-6 text-center text-sm text-red-600 dark:text-red-400">{error}</p>}
          {!error && query.trim().length < 2 && <p className="px-3 py-8 text-center text-sm text-gray-400">{t('codex.search.minimum')}</p>}
          {!error && query.trim().length >= 2 && !loading && results.length === 0 && <p className="px-3 py-8 text-center text-sm text-gray-400">{t('codex.search.empty')}</p>}
          {results.map((result, index) => (
            <button id={`codex-search-result-${index}`} role="option" aria-selected={index === activeIndex} key={`${result.task.host_id || ''}:${result.task.id}`} type="button" onMouseEnter={() => setActiveIndex(index)} onClick={() => { navigate(taskHref(result)); onClose(); }} className={`flex w-full min-w-0 flex-col rounded-md px-3 py-2 text-left hover:bg-black/[0.05] dark:hover:bg-white/[0.07] ${index === activeIndex ? 'bg-black/[0.05] dark:bg-white/[0.07]' : ''}`}>
              <span className="truncate text-sm font-medium">{result.task.summary || result.task.id}</span>
              <span className="mt-0.5 truncate text-xs text-gray-400">{result.task.project_name || result.task.project_id}</span>
            </button>
          ))}
          {offline.length > 0 && <div className="mt-2 border-t border-black/[0.08] px-3 py-2 text-xs text-gray-400 dark:border-white/[0.08]">{offline.map((device) => <p key={device.device_id} className="py-1">{device.device_name} · {device.reason}</p>)}</div>}
        </div>
      </section>
    </div>
  );
}
