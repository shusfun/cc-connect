import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useMatch, useNavigate, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { Bot, Loader2, Menu, Send, User } from 'lucide-react';
import { Modal, Button, useFeedback } from '@/components/ui';
import { listProjects, type ProjectSummary } from '@/api/projects';
import {
  createSession,
  deleteSession,
  getAgentCapabilities,
  getAgentTask,
  listAgentProjects,
  listAgentTasks,
  sendMessage,
  switchSession,
  updateSessionMetadata,
  type AgentProject,
  type AgentSessionCapabilities,
  type AgentTask,
  type AgentTaskHistoryEntry,
  type AgentTaskSnapshot,
} from '@/api/sessions';
import { useClipboard, useLinkBuilder } from '@/hooks/useClipboard';
import { useRefresh } from '@/store/refresh';
import { cn } from '@/lib/utils';
import { WorkspaceChatRail } from './WorkspaceChatRail';

const WEB_SESSION_KEY = 'web:management';

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

function taskPath(projectID: string, taskID: string): string {
  return `/chat/${encodeURIComponent(projectID)}/${encodeURIComponent(taskID)}`;
}

function draftPath(projectID: string): string {
  return `/chat/${encodeURIComponent(projectID)}/new`;
}

function taskLabel(task?: AgentTask): string {
  return task?.summary?.trim() || task?.id.slice(0, 12) || '新任务';
}

function statusLabel(status?: string): string {
  switch (status) {
    case 'active': return '进行中';
    case 'idle':
    case 'completed': return '已完成';
    case 'systemError': return '发生错误';
    default: return status || '状态未知';
  }
}

function mergeHistory(current: AgentTaskHistoryEntry[], incoming: AgentTaskHistoryEntry[]): AgentTaskHistoryEntry[] {
  const values = new Map<string, AgentTaskHistoryEntry>();
  for (const entry of [...current, ...incoming]) {
    values.set(`${entry.timestamp}\u0000${entry.role}\u0000${entry.content}`, entry);
  }
  return [...values.values()].sort((left, right) => left.timestamp.localeCompare(right.timestamp));
}

function normalizeTaskProjects(projects: AgentProject[], tasks: AgentTask[]): { projects: AgentProject[]; tasks: AgentTask[] } {
  const known = new Set(projects.map((project) => project.id));
  const normalized = tasks.map((task) => {
    if (task.project_id && known.has(task.project_id)) return task;
    const byPath = projects.find((project) => project.path && task.cwd === project.path);
    if (byPath) return { ...task, project_id: byPath.id, project_name: byPath.name };
    return { ...task, project_id: '__unassigned__', project_name: '未归类任务' };
  });
  if (normalized.some((task) => task.project_id === '__unassigned__')) {
    return {
      projects: [...projects, { id: '__unassigned__', name: '未归类任务', kind: 'unassigned', is_git_repository: false }],
      tasks: normalized,
    };
  }
  return { projects, tasks: normalized };
}

async function loadAllHistory(bridgeProject: string, taskID: string, hostID?: string): Promise<AgentTaskSnapshot> {
  let cursor = '';
  let snapshot: AgentTaskSnapshot | null = null;
  let history: AgentTaskHistoryEntry[] = [];
  const seen = new Set<string>();
  for (;;) {
    const value = await getAgentTask(bridgeProject, taskID, 10, hostID, cursor || undefined);
    snapshot ||= value;
    history = cursor ? mergeHistory(value.history, history) : mergeHistory(history, value.history);
    if (!value.has_more || !value.cursor) break;
    if (seen.has(value.cursor)) throw new Error('Codex App 历史游标出现循环');
    seen.add(value.cursor);
    cursor = value.cursor;
  }
  if (!snapshot) throw new Error('Codex App 未返回任务快照');
  return { ...snapshot, history, has_more: false, cursor: undefined };
}

function Message({ entry }: { entry: AgentTaskHistoryEntry }) {
  const user = entry.role === 'user';
  return (
    <article className={cn('flex min-w-0 gap-2.5', user && 'justify-end')}>
      {!user && <div className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"><Bot size={15} /></div>}
      <div className={cn('min-w-0 break-words text-sm leading-6', user ? 'max-w-[82%] rounded-lg bg-gray-900 px-3.5 py-2.5 text-white dark:bg-white dark:text-black' : 'max-w-[calc(100%-2.5rem)] flex-1 py-0.5 text-gray-800 dark:text-gray-100')}>
        {user ? <div className="whitespace-pre-wrap">{entry.content}</div> : <div className="prose prose-sm max-w-none break-words dark:prose-invert prose-pre:max-w-full prose-pre:overflow-auto prose-pre:rounded-md prose-a:text-accent"><Markdown remarkPlugins={[remarkGfm]}>{entry.content}</Markdown></div>}
      </div>
      {user && <div className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-gray-200 text-gray-600 dark:bg-gray-700 dark:text-gray-200"><User size={14} /></div>}
    </article>
  );
}

export default function WorkspaceChat() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const params = useParams<{ projectId?: string; taskId?: string }>();
  const draftMatch = useMatch('/chat/:projectId/new');
  const { generation } = useRefresh();
  const { notify, confirm: askConfirmation } = useFeedback();
  const copy = useClipboard();
  const buildLink = useLinkBuilder();
  const [bridgeProject, setBridgeProject] = useState('');
  const [projects, setProjects] = useState<AgentProject[]>([]);
  const [tasks, setTasks] = useState<AgentTask[]>([]);
  const [capabilitiesByHost, setCapabilitiesByHost] = useState<Record<string, AgentSessionCapabilities>>({});
  const [snapshot, setSnapshot] = useState<AgentTaskSnapshot | null>(null);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');
  const [projectPanelOpen, setProjectPanelOpen] = useState(false);
  const [renameTask, setRenameTask] = useState<AgentTask | null>(null);
  const [renameValue, setRenameValue] = useState('');
  const endRef = useRef<HTMLDivElement>(null);
  const selectedTask = useMemo(() => tasks.find((task) => task.id === params.taskId), [params.taskId, tasks]);
  const selectedTaskID = selectedTask?.id;
  const selectedTaskHostID = selectedTask?.host_id;
  const selectedProject = useMemo(() => projects.find((project) => project.id === params.projectId), [params.projectId, projects]);
  const isDraft = draftMatch !== null;

  const loadCatalog = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      const configured = await listProjects();
      const codexProject = (configured.projects || []).find((project: ProjectSummary) => project.agent_type === 'codexapp');
      if (!codexProject) throw new Error('未找到使用 codexapp 的 CC-Connect 项目');
      const [projectResult, taskResult] = await Promise.all([
        listAgentProjects(codexProject.name),
        listAgentTasks(codexProject.name),
      ]);
      const normalized = normalizeTaskProjects(projectResult.projects || [], (taskResult.sessions || []) as AgentTask[]);
      const hostIDs = [...new Set([
        ...normalized.projects.map((project) => project.host_id || ''),
        ...normalized.tasks.map((task) => task.host_id || ''),
      ])];
      const capabilityEntries = await Promise.all(hostIDs.map(async (hostID) => {
        const result = await getAgentCapabilities(codexProject.name, hostID || undefined);
        return [hostID, result.capabilities] as const;
      }));
      setBridgeProject(codexProject.name);
      setProjects(normalized.projects);
      setTasks(normalized.tasks);
      setCapabilitiesByHost(Object.fromEntries(capabilityEntries));
      return { bridgeProject: codexProject.name, ...normalized };
    } catch (cause) {
      setError(errorMessage(cause));
      throw cause;
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    loadCatalog().then(({ projects: nextProjects, tasks: nextTasks }) => {
      if (cancelled || params.projectId) return;
      const firstTask = nextTasks.find((task) => !task.archived && task.project_id);
      if (firstTask?.project_id) navigate(taskPath(firstTask.project_id, firstTask.id), { replace: true });
      else if (nextProjects[0]) navigate(draftPath(nextProjects[0].id), { replace: true });
    }).catch(() => undefined);
    return () => { cancelled = true; };
  }, [generation, loadCatalog, navigate, params.projectId]);

  const refreshSelected = useCallback(async (fullHistory: boolean) => {
    if (!bridgeProject || !selectedTaskID) return;
    const next = fullHistory
      ? await loadAllHistory(bridgeProject, selectedTaskID, selectedTaskHostID)
      : await getAgentTask(bridgeProject, selectedTaskID, 10, selectedTaskHostID);
    setSnapshot((current) => ({ ...next, history: current && !fullHistory ? mergeHistory(current.history, next.history) : next.history }));
    setTasks((current) => current.map((task) => task.id === next.session.id ? { ...task, ...next.session, project_id: task.project_id || next.session.project_id } : task));
    return next;
  }, [bridgeProject, selectedTaskHostID, selectedTaskID]);

  useEffect(() => {
    setSnapshot(null);
    setInput('');
    if (isDraft || !selectedTask || !bridgeProject) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const poll = async (fullHistory: boolean) => {
      let next: AgentTaskSnapshot | undefined;
      try {
        next = await refreshSelected(fullHistory);
        if (!cancelled) setError('');
      } catch (cause) {
        if (!cancelled) setError(errorMessage(cause));
      }
      if (!cancelled) timer = setTimeout(() => void poll(false), next?.session.status === 'active' ? 1200 : 3500);
    };
    void poll(true);
    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
  }, [bridgeProject, isDraft, refreshSelected, selectedTaskID]);

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
  }, [snapshot?.history.length]);

  const submit = async () => {
    const prompt = input.trim();
    if (!prompt || submitting || !bridgeProject) return;
    setSubmitting(true);
    setError('');
    try {
      if (isDraft) {
        if (!selectedProject || selectedProject.kind === 'unassigned') throw new Error('该分组不能创建任务');
        const result = await createSession(bridgeProject, {
          session_key: WEB_SESSION_KEY,
          project_id: selectedProject.id,
          prompt,
          use_local: true,
        });
        if (!result.session?.id) throw new Error('Codex App 创建任务后未返回 task ID');
        setInput('');
        await loadCatalog();
        navigate(taskPath(selectedProject.id, result.session.id), { replace: true });
      } else if (selectedTask) {
        setSnapshot((current) => current ? { ...current, session: { ...current.session, status: 'active' }, history: [...current.history, { role: 'user', content: prompt, timestamp: new Date().toISOString() }] } : current);
        setInput('');
        await switchSession(bridgeProject, { session_key: WEB_SESSION_KEY, session_id: selectedTask.id, host_id: selectedTask.host_id });
        await sendMessage(bridgeProject, { session_key: WEB_SESSION_KEY, message: prompt });
        await refreshSelected(false);
      }
    } catch (cause) {
      const message = errorMessage(cause);
      setError(message);
      notify(message, 'error');
    } finally {
      setSubmitting(false);
    }
  };

  const mutateTask = async (task: AgentTask, patch: { title?: string; pinned?: boolean; archived?: boolean }) => {
    if (!bridgeProject) return;
    try {
      await updateSessionMetadata(bridgeProject, task.id, patch, task.host_id);
      await loadCatalog();
      notify('任务已更新', 'success');
    } catch (cause) {
      notify(errorMessage(cause), 'error');
    }
  };

  const archiveTask = async (task: AgentTask) => {
    if (!bridgeProject) return;
    if (!await askConfirmation({ title: '归档任务', message: `确定归档“${taskLabel(task)}”吗？`, confirmLabel: '归档', danger: true })) return;
    try {
      await deleteSession(bridgeProject, task.id, task.host_id);
      const nextProjectID = task.project_id || params.projectId;
      await loadCatalog();
      if (params.taskId === task.id && nextProjectID) navigate(draftPath(nextProjectID), { replace: true });
      notify('任务已归档', 'success');
    } catch (cause) {
      notify(errorMessage(cause), 'error');
    }
  };

  const copyTaskLink = async (project: AgentProject, task: AgentTask) => {
    try {
      await copy(buildLink(taskPath(project.id, task.id)));
      notify('链接已复制', 'success');
    } catch (cause) {
      notify(errorMessage(cause), 'error');
    }
  };

  const history = snapshot?.history || [];
  const currentTask = snapshot?.session || selectedTask;
  const composerDisabled = submitting || !bridgeProject || !selectedProject || (!isDraft && !selectedTask);

  return (
    <div className="relative flex h-[calc(100dvh-9.5rem)] min-h-[32rem] overflow-hidden rounded-lg border border-gray-200 bg-white dark:border-white/[0.08] dark:bg-[#0b0b0d]">
      <WorkspaceChatRail
        open={projectPanelOpen}
        loading={loading}
        projects={projects}
        tasks={tasks}
        capabilitiesByHost={capabilitiesByHost}
        selectedProjectID={params.projectId}
        selectedTaskID={isDraft ? undefined : params.taskId}
        onClose={() => setProjectPanelOpen(false)}
        onNewTask={(project) => { navigate(draftPath(project.id)); setProjectPanelOpen(false); }}
        onTask={(project, task) => { navigate(taskPath(project.id, task.id)); setProjectPanelOpen(false); }}
        onRenameTask={(task) => { setRenameTask(task); setRenameValue(taskLabel(task)); }}
        onTogglePin={(task) => void mutateTask(task, { pinned: !task.pinned })}
        onArchiveTask={(task) => void archiveTask(task)}
        onCopyLink={(project, task) => void copyTaskLink(project, task)}
      />

      <section className="flex min-w-0 flex-1 flex-col">
        <header className="flex min-h-14 shrink-0 items-center gap-2 border-b border-gray-200 px-3 sm:px-4 dark:border-white/[0.08]">
          <button type="button" className="rounded-md p-1.5 hover:bg-gray-100 md:hidden dark:hover:bg-white/[0.08]" onClick={() => setProjectPanelOpen(true)} aria-label={t('workspaceChat.openProjects', '打开项目列表')}><Menu size={18} /></button>
          <div className="min-w-0 flex-1">
            <div className="truncate text-sm font-semibold text-gray-900 dark:text-white">{isDraft ? '新建任务' : taskLabel(currentTask)}</div>
            <div className="flex min-w-0 items-center gap-2 text-[11px] text-gray-400">
              <span className="truncate">{selectedProject?.name || currentTask?.project_name || 'Codex App'}</span>
              {currentTask?.id && <span className="hidden truncate font-mono sm:inline">{currentTask.id}</span>}
            </div>
          </div>
          {!isDraft && currentTask && (
            <div className="flex items-center gap-1.5 text-xs text-gray-500 dark:text-gray-400">
              <span className={cn('h-2 w-2 rounded-full', currentTask.status === 'active' ? 'bg-emerald-500' : currentTask.status === 'systemError' ? 'bg-red-500' : 'bg-gray-400')} />
              <span>{statusLabel(currentTask.status)}</span>
            </div>
          )}
        </header>

        <main className="min-h-0 flex-1 overflow-y-auto px-3 sm:px-5">
          {loading && projects.length === 0 ? (
            <div className="flex h-full items-center justify-center"><Loader2 className="animate-spin text-accent" size={24} /></div>
          ) : !params.projectId ? (
            <div className="flex h-full items-center justify-center text-center text-sm text-gray-400">从左侧选择 Codex App 项目或任务</div>
          ) : isDraft ? (
            <div className="mx-auto flex h-full max-w-2xl flex-col justify-center py-10">
              <Bot size={28} className="mb-4 text-emerald-600 dark:text-emerald-400" />
              <h1 className="text-xl font-semibold text-gray-900 dark:text-white">{selectedProject?.name || '新建任务'}</h1>
              <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">首条消息发送后，任务会由当前 Codex App 创建并接管。</p>
            </div>
          ) : history.length === 0 && !error ? (
            <div className="flex h-full items-center justify-center text-sm text-gray-400">{snapshot ? '当前任务还没有消息' : <Loader2 className="animate-spin text-accent" size={22} />}</div>
          ) : (
            <div className="mx-auto w-full max-w-4xl space-y-6 py-6">
              {history.map((entry, index) => <Message key={`${entry.timestamp}-${entry.role}-${index}`} entry={entry} />)}
              {currentTask?.status === 'active' && <div className="flex items-center gap-2 pl-9 text-xs text-gray-400"><Loader2 size={13} className="animate-spin" />Codex 正在处理</div>}
              <div ref={endRef} />
            </div>
          )}
        </main>

        {error && <div role="alert" className="shrink-0 border-t border-red-200 bg-red-50 px-4 py-2 text-xs text-red-700 dark:border-red-900/50 dark:bg-red-950/30 dark:text-red-300">{error}</div>}

        <footer className="shrink-0 border-t border-gray-200 px-3 py-3 dark:border-white/[0.08]">
          <div className="mx-auto flex max-w-4xl items-end gap-2 rounded-lg border border-gray-300 bg-white p-2 focus-within:border-gray-500 dark:border-white/[0.14] dark:bg-black/20">
            <textarea
              value={input}
              onChange={(event) => setInput(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === 'Enter' && !event.shiftKey) {
                  event.preventDefault();
                  void submit();
                }
              }}
              disabled={composerDisabled}
              rows={2}
              placeholder={isDraft ? '描述你要 Codex 完成的任务' : currentTask?.status === 'active' ? '向当前任务补充消息' : '给 Codex 发送消息'}
              className="max-h-36 min-h-[44px] min-w-0 flex-1 resize-none border-0 bg-transparent px-1 py-1 text-sm outline-none disabled:opacity-50"
            />
            <button type="button" onClick={() => void submit()} disabled={!input.trim() || composerDisabled} className="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-gray-900 text-white hover:bg-black disabled:opacity-35 dark:bg-white dark:text-black dark:hover:bg-gray-200" title="发送" aria-label="发送">
              {submitting ? <Loader2 size={17} className="animate-spin" /> : <Send size={17} />}
            </button>
          </div>
        </footer>
      </section>

      <Modal open={renameTask !== null} onClose={() => setRenameTask(null)} title="重命名任务">
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300" htmlFor="task-title">任务标题</label>
        <input id="task-title" value={renameValue} onChange={(event) => setRenameValue(event.target.value)} className="mt-2 w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm outline-none focus:border-accent dark:border-white/[0.14] dark:bg-black/30" />
        <div className="mt-5 flex justify-end gap-2">
          <Button variant="ghost" onClick={() => setRenameTask(null)}>取消</Button>
          <Button disabled={!renameValue.trim()} onClick={() => {
            if (!renameTask) return;
            void mutateTask(renameTask, { title: renameValue.trim() });
            setRenameTask(null);
          }}>保存</Button>
        </div>
      </Modal>
    </div>
  );
}
