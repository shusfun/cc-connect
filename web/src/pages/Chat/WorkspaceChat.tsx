import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useVirtualizer } from '@tanstack/react-virtual';
import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { ArrowDown, Check, ChevronDown, Circle, CircleAlert, Loader2, Send } from 'lucide-react';
import {
  createCodexTask,
  postCodexMessage,
  readCodexTask,
  waitCodexTask,
  type CodexItem,
  type CodexTask,
  type CodexTurn,
} from '@/api/codex';
import { cn } from '@/lib/utils';
import { useCodexWorkspace } from './CodexWorkspaceContext';
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';

const messageOf = (cause: unknown) => cause instanceof Error ? cause.message : String(cause);
const taskLabel = (task: CodexTask | undefined, fallback: string) => task?.summary?.trim() || task?.id.slice(0, 12) || fallback;
const taskHref = (deviceID: string, projectID: string, taskID: string) =>
  `/tasks/${encodeURIComponent(deviceID)}/${encodeURIComponent(projectID)}/${encodeURIComponent(taskID)}`;

function mergeTurns(current: CodexTurn[], incoming: CodexTurn[], prepend = false): CodexTurn[] {
  const incomingByID = new Map(incoming.map((turn) => [turn.id, turn]));
  const currentIDs = new Set(current.map((turn) => turn.id));
  if (prepend) {
    return [
      ...incoming.filter((turn) => !currentIDs.has(turn.id)),
      ...current.map((turn) => incomingByID.get(turn.id) || turn),
    ];
  }
  return [
    ...current.map((turn) => incomingByID.get(turn.id) || turn),
    ...incoming.filter((turn) => !currentIDs.has(turn.id)),
  ];
}

function statusLabel(t: TFunction, status?: string) {
  switch (status) {
    case 'active':
    case 'in_progress': return t('codex.status.inProgress');
    case 'pending': return t('codex.status.pending');
    case 'idle':
    case 'completed': return t('codex.status.completed');
    case 'cancelled': return t('codex.status.cancelled');
    case 'failed':
    case 'systemError': return t('codex.status.failed');
    default: return status || t('codex.status.unknown');
  }
}

function PlanBody({ item }: { item: CodexItem }) {
  const { t } = useTranslation();
  const content = (item.content || []).filter((part) => part.type === 'text').map((part) => part.text || '').join('\n').trim();
  if (content) return <Markdown remarkPlugins={[remarkGfm]}>{content}</Markdown>;
  if (typeof item.raw_content === 'string' && item.raw_content.trim()) {
    return <Markdown remarkPlugins={[remarkGfm]}>{item.raw_content}</Markdown>;
  }
  if (item.raw_content && typeof item.raw_content === 'object' && !Array.isArray(item.raw_content)) {
    const steps = (item.raw_content as { steps?: unknown }).steps;
    if (Array.isArray(steps)) {
      const normalized = steps.flatMap((value) => {
        if (!value || typeof value !== 'object' || Array.isArray(value)) return [];
        const step = value as { title?: unknown; step?: unknown; status?: unknown };
        const label = typeof step.title === 'string' ? step.title : typeof step.step === 'string' ? step.step : '';
        if (!label.trim()) return [];
        return [{ label, status: typeof step.status === 'string' ? step.status : '' }];
      });
      if (normalized.length > 0) {
        return (
          <ol className="not-prose space-y-2">
            {normalized.map((step, index) => {
              const completed = step.status === 'completed';
              return (
                <li key={`${index}:${step.label}`} className="flex items-start gap-2 text-sm leading-5">
                  <span className={cn('mt-0.5 grid h-4 w-4 shrink-0 place-items-center rounded-full border', completed ? 'border-emerald-500 bg-emerald-500 text-white' : 'border-gray-400 text-gray-400')}>
                    {completed ? <Check size={11} /> : <Circle size={8} />}
                  </span>
                  <span className="min-w-0 flex-1 break-words">{step.label}</span>
                  {step.status && <span className="shrink-0 text-xs text-gray-400">{statusLabel(t, step.status)}</span>}
                </li>
              );
            })}
          </ol>
        );
      }
    }
  }
  if (item.raw_content !== undefined && item.raw_content !== null) {
    return <pre className="max-w-full overflow-auto whitespace-pre-wrap break-words text-xs">{JSON.stringify(item.raw_content, null, 2)}</pre>;
  }
  return <Markdown remarkPlugins={[remarkGfm]}>{item.text || ''}</Markdown>;
}

function ItemView({ item, taskID, expanded, onToggle }: { item: CodexItem; taskID: string; expanded: boolean; onToggle: () => void }) {
  const { t } = useTranslation();
  if (item.type === 'user_message') {
    const text = (item.content || []).filter((part) => part.type === 'text').map((part) => part.text || '').join('\n');
    return <div className="flex justify-end"><div className="max-w-[82%] whitespace-pre-wrap break-words rounded-lg bg-[#ececea] px-3.5 py-2.5 text-sm leading-6 text-gray-950 dark:bg-white/[0.1] dark:text-white">{text}</div></div>;
  }
  if (item.type === 'agent_message') {
    return <div className="prose prose-sm max-w-none break-words text-gray-800 dark:prose-invert dark:text-gray-100 prose-pre:max-w-full prose-pre:overflow-auto prose-pre:rounded-md"><Markdown remarkPlugins={[remarkGfm]}>{item.text || ''}</Markdown></div>;
  }
  if (item.type === 'plan') {
    const explicitTitle = item.text?.trim().replace(/\s+/g, ' ') || '';
    const title = explicitTitle ? explicitTitle.slice(0, 80) : t('codex.plan');
    return (
      <section className="overflow-hidden rounded-md border border-black/[0.09] bg-[#fafaf8] dark:border-white/[0.1] dark:bg-white/[0.035]" data-plan-key={`${taskID}:${item.id}`}>
        <button type="button" aria-expanded={expanded} onClick={onToggle} className="flex w-full items-center gap-2 px-3 py-2 text-left text-xs hover:bg-black/[0.035] dark:hover:bg-white/[0.04]">
          <ChevronDown size={14} className={cn('shrink-0 transition-transform', !expanded && '-rotate-90')} />
          <span className="min-w-0 flex-1 truncate font-medium">{title}</span>
          <span className="shrink-0 text-gray-400">{statusLabel(t, item.status)}</span>
        </button>
        {expanded && <div className="border-t border-black/[0.07] px-3 py-2 text-sm dark:border-white/[0.08]"><div className="prose prose-sm max-w-none dark:prose-invert"><PlanBody item={item} /></div></div>}
      </section>
    );
  }
  return (
    <div className="flex items-center gap-2 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800 dark:border-amber-900/50 dark:bg-amber-950/25 dark:text-amber-300">
      <CircleAlert size={14} /><span>{t('codex.unsupportedItem', { type: item.source_type || item.type })}</span>
    </div>
  );
}

function TurnView({ turn, taskID, expandedPlans, onTogglePlan }: { turn: CodexTurn; taskID: string; expandedPlans: Set<string>; onTogglePlan: (itemID: string) => void }) {
  return (
    <article data-turn-id={turn.id} className="space-y-5 py-3">
      {turn.items.map((item) => <ItemView key={item.id} item={item} taskID={taskID} expanded={expandedPlans.has(item.id)} onToggle={() => onTogglePlan(item.id)} />)}
    </article>
  );
}

export default function WorkspaceChat() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const params = useParams<{ deviceID?: string; projectID?: string; taskID?: string }>();
  const workspace = useCodexWorkspace();
  const [task, setTask] = useState<CodexTask | undefined>();
  const [turns, setTurns] = useState<CodexTurn[]>([]);
  const [historyCursor, setHistoryCursor] = useState('');
  const [hasMore, setHasMore] = useState(false);
  const [waitCursor, setWaitCursor] = useState('');
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const [loadingOlder, setLoadingOlder] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');
  const [atBottom, setAtBottom] = useState(true);
  const [expandedPlans, setExpandedPlans] = useState<Set<string>>(new Set());
  const scrollRef = useRef<HTMLDivElement>(null);
  const composerRef = useRef<HTMLTextAreaElement>(null);
  const initialScrollRef = useRef(false);
  const anchorRef = useRef<{ id: string; delta: number } | null>(null);
  const atBottomRef = useRef(true);

  const project = workspace.projects.find((value) => value.device_id === params.deviceID && value.project_id === params.projectID);
  const isDraft = params.taskID === 'new';
  const knownTask = project ? workspace.pages[workspace.keyFor(project)]?.tasks.find((value) => value.id === params.taskID) : undefined;
  const hostID = task?.host_id || knownTask?.host_id || '';

  useEffect(() => {
    if (params.deviceID || workspace.loading || workspace.error) return;
    const firstProject = workspace.projects.find((value) => value.online && value.available);
    if (!firstProject) return;
    const firstTask = workspace.pages[workspace.keyFor(firstProject)]?.tasks[0];
    navigate(taskHref(firstProject.device_id, firstProject.project_id, firstTask?.id || 'new'), { replace: true });
  }, [navigate, params.deviceID, workspace]);

  const virtualizer = useVirtualizer({
    count: turns.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 220,
    getItemKey: (index) => turns[index]?.id || index,
    measureElement: (element) => element.getBoundingClientRect().height,
    overscan: 6,
    initialRect: { width: 800, height: 600 },
  });

  const scrollToBottom = useCallback((behavior: ScrollBehavior = 'smooth') => {
    const element = scrollRef.current;
    if (!element) return;
    element.scrollTo({ top: element.scrollHeight, behavior });
    atBottomRef.current = true;
    setAtBottom(true);
  }, []);

  useLayoutEffect(() => {
    if (anchorRef.current) {
      const anchor = anchorRef.current;
      anchorRef.current = null;
      const index = turns.findIndex((turn) => turn.id === anchor.id);
      if (index >= 0) {
        virtualizer.scrollToIndex(index, { align: 'start' });
        requestAnimationFrame(() => {
          const row = virtualizer.getVirtualItems().find((item) => item.index === index);
          if (row && scrollRef.current) scrollRef.current.scrollTop = row.start + anchor.delta;
        });
      }
      return;
    }
    if (!initialScrollRef.current && turns.length > 0) {
      initialScrollRef.current = true;
      requestAnimationFrame(() => scrollToBottom('auto'));
    } else if (atBottomRef.current && turns.length > 0) {
      requestAnimationFrame(() => scrollToBottom('auto'));
    }
  }, [scrollToBottom, turns, virtualizer]);

  useEffect(() => {
    setExpandedPlans(new Set());
    if (!params.taskID || params.taskID === 'new') return;
    const prefix = `cc-connect:plan:${params.taskID}:`;
    const restored = new Set<string>();
    for (let index = 0; index < sessionStorage.length; index++) {
      const key = sessionStorage.key(index);
      if (key?.startsWith(prefix) && sessionStorage.getItem(key) === 'open') restored.add(key.slice(prefix.length));
    }
    setExpandedPlans(restored);
  }, [params.taskID]);

  useEffect(() => {
    setTask(knownTask);
    setTurns([]);
    setHistoryCursor('');
    setHasMore(false);
    setWaitCursor('');
    setInput('');
    setError('');
    initialScrollRef.current = false;
    if (!project || isDraft || !params.taskID) return;
    let cancelled = false;
    setLoading(true);
    readCodexTask(project.device_id, project.project_id, params.taskID, '', knownTask?.host_id || '', 10)
      .then((snapshot) => {
        if (cancelled) return;
        setTask(snapshot.task);
        setTurns(snapshot.turns || []);
        setHistoryCursor(snapshot.page.cursor || '');
        setHasMore(snapshot.page.has_more);
        setWaitCursor(snapshot.wait_cursor || '');
        workspace.upsertTask(project, snapshot.task);
      })
      .catch((cause) => { if (!cancelled) setError(messageOf(cause)); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [isDraft, knownTask?.host_id, params.taskID, project?.device_id, project?.project_id]);

  useEffect(() => {
    if (!project || isDraft || !params.taskID || loading || error) return;
    let cancelled = false;
    let cursor = waitCursor;
    const poll = async () => {
      while (!cancelled) {
        try {
          const snapshot = await waitCodexTask(project.device_id, project.project_id, params.taskID!, cursor, hostID, 30_000);
          if (cancelled) return;
          cursor = snapshot.wait_cursor || cursor;
          setWaitCursor(cursor);
          setTask(snapshot.task);
          setTurns((current) => mergeTurns(current, snapshot.turns || []));
          workspace.upsertTask(project, snapshot.task);
          setError('');
        } catch (cause) {
          if (!cancelled) setError(messageOf(cause));
          return;
        }
      }
    };
    void poll();
    return () => { cancelled = true; };
  }, [error, hostID, isDraft, loading, params.taskID, project?.device_id, project?.project_id, waitCursor]);

  const loadOlder = useCallback(async () => {
    const element = scrollRef.current;
    const first = virtualizer.getVirtualItems()[0];
    if (!project || !params.taskID || !historyCursor || !hasMore || loadingOlder || !element || !first) return;
    anchorRef.current = { id: turns[first.index].id, delta: element.scrollTop - first.start };
    setLoadingOlder(true);
    try {
      const snapshot = await readCodexTask(project.device_id, project.project_id, params.taskID, historyCursor, hostID, 10);
      setTurns((current) => mergeTurns(current, snapshot.turns || [], true));
      setHistoryCursor(snapshot.page.cursor || '');
      setHasMore(snapshot.page.has_more);
    } catch (cause) {
      anchorRef.current = null;
      setError(messageOf(cause));
    } finally {
      setLoadingOlder(false);
    }
  }, [hasMore, historyCursor, hostID, loadingOlder, params.taskID, project, turns, virtualizer]);

  const onScroll = () => {
    const element = scrollRef.current;
    if (!element) return;
    const bottom = element.scrollHeight - element.scrollTop - element.clientHeight <= 48;
    atBottomRef.current = bottom;
    setAtBottom(bottom);
    if (element.scrollTop <= 80) void loadOlder();
  };

  const togglePlan = (itemID: string) => {
    if (!params.taskID) return;
    setExpandedPlans((current) => {
      const next = new Set(current);
      const key = `cc-connect:plan:${params.taskID}:${itemID}`;
      if (next.has(itemID)) {
        next.delete(itemID);
        sessionStorage.removeItem(key);
      } else {
        next.add(itemID);
        sessionStorage.setItem(key, 'open');
      }
      return next;
    });
  };

  useEffect(() => {
    const composer = composerRef.current;
    if (!composer) return;
    composer.style.height = '0px';
    composer.style.height = `${Math.min(composer.scrollHeight, 144)}px`;
  }, [input]);

  const submit = async () => {
    const prompt = input.trim();
    if (!prompt || !project || !params.taskID || submitting) return;
    setSubmitting(true);
    setError('');
    try {
      if (isDraft) {
        const created = await createCodexTask(project.device_id, project.project_id, prompt);
        workspace.upsertTask(project, created);
        setInput('');
        navigate(taskHref(project.device_id, project.project_id, created.id), { replace: true });
      } else {
        await postCodexMessage(project.device_id, project.project_id, params.taskID, prompt, hostID);
        setInput('');
      }
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setSubmitting(false);
    }
  };

  const currentTask = task || knownTask;
	const measuredVirtualItems = virtualizer.getVirtualItems();
	const virtualItems = measuredVirtualItems.length > 0
		? measuredVirtualItems
		: turns.slice(0, 12).map((_, index) => ({ index, start: index * 220 }));
  const composerDisabled = !project || !params.taskID || submitting || (!isDraft && !currentTask);
  const emptyReason = !workspace.loading && workspace.projects.length === 0
    ? t('codex.noAvailableProjects')
    : project && (!project.online || !project.available)
      ? project.reason || t('codex.runtimeOffline')
      : !params.taskID ? t('codex.noSelectedTask') : '';

  return (
    <section className="flex min-h-0 flex-1 flex-col bg-white dark:bg-[#111110]">
      <header className="flex h-12 shrink-0 items-center gap-3 border-b border-black/[0.08] pl-14 pr-4 md:px-4 dark:border-white/[0.08]">
        <div className="min-w-0 flex-1">
          <div className="truncate text-sm font-medium">{isDraft ? t('codex.newTask') : taskLabel(currentTask, t('codex.newTask'))}</div>
          <div className="truncate text-[11px] text-gray-400">{project?.project_name || 'CC-Connect'}</div>
        </div>
        {!isDraft && currentTask && <div className="flex items-center gap-1.5 text-xs text-gray-500"><span className={cn('h-2 w-2 rounded-full', currentTask.status === 'active' ? 'bg-emerald-500' : currentTask.status === 'systemError' ? 'bg-red-500' : 'bg-gray-400')} />{statusLabel(t, currentTask.status)}</div>}
      </header>

      <div ref={scrollRef} onScroll={onScroll} className="relative min-h-0 flex-1 overflow-y-auto overscroll-contain px-3 sm:px-5">
        {loading && <div className="grid h-full place-items-center"><Loader2 size={22} className="animate-spin text-gray-400" /></div>}
        {!loading && emptyReason && <div className="grid h-full place-items-center px-6 text-center text-sm text-gray-400">{emptyReason}</div>}
        {!loading && isDraft && project && <div className="mx-auto flex h-full max-w-3xl items-center px-2"><h1 className="text-xl font-semibold">{project.project_name}</h1></div>}
        {!loading && !isDraft && params.taskID && turns.length === 0 && !error && <div className="grid h-full place-items-center text-sm text-gray-400">{t('codex.emptyTask')}</div>}
        {!loading && !isDraft && turns.length > 0 && (
          <div className="mx-auto w-full max-w-3xl py-4">
            {loadingOlder && <div className="absolute left-1/2 top-2 z-10 -translate-x-1/2 rounded-md bg-white/90 p-1.5 shadow dark:bg-[#222220]"><Loader2 size={14} className="animate-spin" /></div>}
            <div style={{ height: `${virtualizer.getTotalSize()}px`, position: 'relative' }}>
              {virtualItems.map((virtualRow) => {
                const turn = turns[virtualRow.index];
                return (
                  <div key={turn.id} data-index={virtualRow.index} ref={virtualizer.measureElement} className="absolute left-0 top-0 w-full" style={{ transform: `translateY(${virtualRow.start}px)` }}>
                    <TurnView turn={turn} taskID={params.taskID!} expandedPlans={expandedPlans} onTogglePlan={togglePlan} />
                  </div>
                );
              })}
            </div>
          </div>
        )}
      </div>

      {!atBottom && turns.length > 0 && <button type="button" onClick={() => scrollToBottom()} className="absolute bottom-24 left-1/2 z-10 grid h-9 w-9 -translate-x-1/2 place-items-center rounded-full border border-black/[0.1] bg-white shadow-md hover:bg-gray-50 dark:border-white/[0.12] dark:bg-[#252523] dark:hover:bg-[#30302d]" aria-label={t('codex.backToBottom')}><ArrowDown size={17} /></button>}
      {error && <div role="alert" className="shrink-0 border-t border-red-200 bg-red-50 px-4 py-2 text-xs text-red-700 dark:border-red-900/50 dark:bg-red-950/30 dark:text-red-300">{error}</div>}

      <footer className="shrink-0 bg-white px-3 pb-4 pt-2 dark:bg-[#111110]">
        <div className="mx-auto flex max-w-3xl items-end gap-2 rounded-lg border border-gray-300 bg-white p-2 shadow-sm focus-within:border-gray-500 focus-within:ring-2 focus-within:ring-gray-200 dark:border-white/[0.14] dark:bg-[#1b1b19] dark:focus-within:border-white/25 dark:focus-within:ring-white/[0.06]">
          <textarea ref={composerRef} value={input} onChange={(event) => setInput(event.target.value)} onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); void submit(); }
          }} disabled={composerDisabled} rows={1} placeholder={isDraft ? t('codex.newTaskPlaceholder') : t('codex.messagePlaceholder')} className="max-h-36 min-h-10 min-w-0 flex-1 resize-none overflow-y-auto border-0 bg-transparent px-1 py-2 text-sm leading-6 outline-none disabled:opacity-50" />
          <button type="button" onClick={() => void submit()} disabled={!input.trim() || composerDisabled} className="grid h-9 w-9 shrink-0 place-items-center rounded-md bg-gray-900 text-white hover:bg-black disabled:opacity-35 dark:bg-white dark:text-black dark:hover:bg-gray-200" title={t('codex.send')} aria-label={t('codex.send')}>{submitting ? <Loader2 size={17} className="animate-spin" /> : <Send size={17} />}</button>
        </div>
      </footer>
    </section>
  );
}
