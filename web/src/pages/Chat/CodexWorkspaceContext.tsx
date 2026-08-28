import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import {
  listCodexProjects,
  listCodexTasks,
  type CodexProject,
  type CodexTask,
} from '@/api/codex';
import { useRefresh } from '@/store/refresh';
import i18n from '@/i18n';

export interface CodexProjectTasks {
  tasks: CodexTask[];
  cursor: string;
  hasMore: boolean;
  expanded: boolean;
  loading: boolean;
  error: string;
}

interface CodexWorkspaceValue {
  projects: CodexProject[];
  pages: Record<string, CodexProjectTasks>;
  loading: boolean;
  error: string;
  keyFor: (project: CodexProject) => string;
  loadMore: (project: CodexProject) => Promise<void>;
  showLess: (project: CodexProject) => void;
  reload: () => Promise<void>;
  upsertTask: (project: CodexProject, task: CodexTask) => void;
  removeTask: (project: CodexProject, taskID: string, hostID?: string) => void;
}

const CodexWorkspaceContext = createContext<CodexWorkspaceValue | null>(null);

const messageOf = (cause: unknown) => cause instanceof Error ? cause.message : String(cause);
const projectKey = (project: CodexProject) => `${project.device_id}\u0000${project.project_id}`;
const taskKey = (task: CodexTask) => `${task.host_id || ''}\u0000${task.id}`;

function mergeTasks(current: CodexTask[], incoming: CodexTask[]): CodexTask[] {
  const values = new Map(current.map((task) => [taskKey(task), task]));
  for (const task of incoming) values.set(taskKey(task), { ...values.get(taskKey(task)), ...task });
  return [...values.values()].sort((left, right) =>
    Number(Boolean(right.pinned)) - Number(Boolean(left.pinned)) ||
    (right.modified_at || '').localeCompare(left.modified_at || ''));
}

export function CodexWorkspaceProvider({ children }: { children: ReactNode }) {
  const { generation } = useRefresh();
  const [projects, setProjects] = useState<CodexProject[]>([]);
  const [pages, setPages] = useState<Record<string, CodexProjectTasks>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const reload = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      const result = await listCodexProjects();
      const nextProjects = (result.projects || []).sort((left, right) => left.order - right.order);
      setProjects(nextProjects);
      const initialPages = await Promise.all(nextProjects.map(async (project) => {
        const key = projectKey(project);
        if (!project.online || !project.available) {
          return [key, { tasks: [], cursor: '', hasMore: false, expanded: false, loading: false, error: project.reason || i18n.t('codex.runtimeOffline') }] as const;
        }
        try {
          const page = await listCodexTasks(project.device_id, project.project_id, '', 5);
          return [key, { tasks: page.sessions || [], cursor: page.cursor || '', hasMore: page.has_more, expanded: false, loading: false, error: '' }] as const;
        } catch (cause) {
          return [key, { tasks: [], cursor: '', hasMore: false, expanded: false, loading: false, error: messageOf(cause) }] as const;
        }
      }));
      setPages(Object.fromEntries(initialPages));
    } catch (cause) {
      setError(messageOf(cause));
      setProjects([]);
      setPages({});
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void reload(); }, [generation, reload]);

  const loadMore = useCallback(async (project: CodexProject) => {
    const key = projectKey(project);
    const current = pages[key];
    if (!current || current.loading) return;
    if (!current.hasMore) {
      setPages((value) => ({ ...value, [key]: { ...value[key], expanded: true } }));
      return;
    }
    setPages((value) => ({ ...value, [key]: { ...value[key], loading: true, error: '' } }));
    try {
      const next = await listCodexTasks(project.device_id, project.project_id, current.cursor, 20);
      setPages((value) => ({
        ...value,
        [key]: {
          ...value[key],
          tasks: mergeTasks(value[key].tasks, next.sessions || []),
          cursor: next.cursor || '',
          hasMore: next.has_more,
          expanded: true,
          loading: false,
        },
      }));
    } catch (cause) {
      setPages((value) => ({ ...value, [key]: { ...value[key], loading: false, error: messageOf(cause) } }));
    }
  }, [pages]);

  const showLess = useCallback((project: CodexProject) => {
    const key = projectKey(project);
    setPages((value) => ({ ...value, [key]: { ...value[key], expanded: false } }));
  }, []);

  const upsertTask = useCallback((project: CodexProject, task: CodexTask) => {
    const key = projectKey(project);
    setPages((value) => ({
      ...value,
      [key]: { ...value[key], tasks: mergeTasks(value[key]?.tasks || [], [task]) },
    }));
  }, []);

  const removeTask = useCallback((project: CodexProject, taskID: string, hostID = '') => {
    const key = projectKey(project);
    setPages((value) => ({
      ...value,
      [key]: {
        ...value[key],
        tasks: (value[key]?.tasks || []).filter((task) => task.id !== taskID || (hostID && task.host_id !== hostID)),
      },
    }));
  }, []);

  const value = useMemo<CodexWorkspaceValue>(() => ({
    projects, pages, loading, error, keyFor: projectKey, loadMore, showLess, reload, upsertTask, removeTask,
  }), [error, loadMore, loading, pages, projects, reload, removeTask, showLess, upsertTask]);

  return <CodexWorkspaceContext.Provider value={value}>{children}</CodexWorkspaceContext.Provider>;
}

export function useCodexWorkspace() {
  const value = useContext(CodexWorkspaceContext);
  if (!value) throw new Error('useCodexWorkspace 必须在 CodexWorkspaceProvider 中使用');
  return value;
}
