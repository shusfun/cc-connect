import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react';
import { AlertCircle, CheckCircle2, Info, X } from 'lucide-react';
import { Button } from './Button';
import { Modal } from './Modal';

type NoticeKind = 'success' | 'error' | 'info';

interface Notice {
  id: number;
  message: string;
  kind: NoticeKind;
}

interface ConfirmOptions {
  title: string;
  message: string;
  confirmLabel?: string;
  danger?: boolean;
}

interface FeedbackContextValue {
  notify: (message: string, kind?: NoticeKind) => void;
  confirm: (options: ConfirmOptions) => Promise<boolean>;
}

const FeedbackContext = createContext<FeedbackContextValue | null>(null);

export function FeedbackProvider({ children }: { children: ReactNode }) {
  const [notices, setNotices] = useState<Notice[]>([]);
  const [confirmation, setConfirmation] = useState<(ConfirmOptions & { resolve: (value: boolean) => void }) | null>(null);

  const dismiss = useCallback((id: number) => setNotices((current) => current.filter((notice) => notice.id !== id)), []);
  const notify = useCallback((message: string, kind: NoticeKind = 'info') => {
    const id = Date.now() + Math.random();
    setNotices((current) => [...current, { id, message, kind }]);
    setTimeout(() => dismiss(id), 4200);
  }, [dismiss]);
  const confirm = useCallback((options: ConfirmOptions) => new Promise<boolean>((resolve) => {
    setConfirmation({ ...options, resolve });
  }), []);
  const resolveConfirmation = useCallback((value: boolean) => {
    setConfirmation((current) => {
      current?.resolve(value);
      return null;
    });
  }, []);
  const value = useMemo(() => ({ notify, confirm }), [confirm, notify]);

  return (
    <FeedbackContext.Provider value={value}>
      {children}
      <div className="pointer-events-none fixed right-3 top-16 z-[10000] flex w-[min(24rem,calc(100vw-1.5rem))] flex-col gap-2" aria-live="polite">
        {notices.map((notice) => {
          const Icon = notice.kind === 'success' ? CheckCircle2 : notice.kind === 'error' ? AlertCircle : Info;
          return (
            <div key={notice.id} role={notice.kind === 'error' ? 'alert' : 'status'} className="pointer-events-auto flex items-start gap-2 rounded-lg border border-gray-200 bg-white px-3 py-2.5 text-sm text-gray-800 shadow-lg dark:border-white/[0.1] dark:bg-[#151517] dark:text-gray-100">
              <Icon size={16} className={notice.kind === 'error' ? 'mt-0.5 text-red-500' : notice.kind === 'success' ? 'mt-0.5 text-emerald-500' : 'mt-0.5 text-blue-500'} />
              <span className="min-w-0 flex-1 break-words">{notice.message}</span>
              <button type="button" onClick={() => dismiss(notice.id)} className="rounded p-0.5 text-gray-400 hover:bg-gray-100 dark:hover:bg-white/[0.08]" aria-label="关闭"><X size={14} /></button>
            </div>
          );
        })}
      </div>
      <Modal open={confirmation !== null} onClose={() => resolveConfirmation(false)} title={confirmation?.title || ''}>
        <p className="text-sm leading-6 text-gray-600 dark:text-gray-300">{confirmation?.message}</p>
        <div className="mt-5 flex justify-end gap-2">
          <Button variant="ghost" onClick={() => resolveConfirmation(false)}>取消</Button>
          <Button variant={confirmation?.danger ? 'danger' : 'primary'} onClick={() => resolveConfirmation(true)}>{confirmation?.confirmLabel || '确认'}</Button>
        </div>
      </Modal>
    </FeedbackContext.Provider>
  );
}

export function useFeedback(): FeedbackContextValue {
  const value = useContext(FeedbackContext);
  if (!value) throw new Error('useFeedback must be used inside FeedbackProvider');
  return value;
}
