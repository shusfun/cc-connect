import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import {
  Archive,
  ChevronDown,
  ChevronRight,
  Copy,
  Folder,
  FolderGit2,
  MoreHorizontal,
  Pencil,
  Pin,
  PinOff,
  Plus,
  X,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import type { AgentProject, AgentSessionCapabilities, AgentTask } from '@/api/sessions';

interface Props {
  open: boolean;
  loading: boolean;
  projects: AgentProject[];
  tasks: AgentTask[];
  capabilitiesByHost: Record<string, AgentSessionCapabilities>;
  selectedProjectID?: string;
  selectedTaskID?: string;
  onClose: () => void;
  onNewTask: (project: AgentProject) => void;
  onTask: (project: AgentProject, task: AgentTask) => void;
  onRenameTask: (task: AgentTask) => void;
  onTogglePin: (task: AgentTask) => void;
  onArchiveTask: (task: AgentTask) => void;
  onCopyLink: (project: AgentProject, task: AgentTask) => void;
}

function taskLabel(task: AgentTask): string {
  return task.summary?.trim() || task.id.slice(0, 12);
}

function taskStatus(status?: string): string {
  switch (status) {
    case 'active': return '进行中';
    case 'idle':
    case 'completed': return '已完成';
    case 'systemError': return '发生错误';
    default: return status || '状态未知';
  }
}

function ActionMenu({ label, open, onToggle, onClose, children }: {
  label: string;
  open: boolean;
  onToggle: () => void;
  onClose: () => void;
  children: ReactNode;
}) {
  const rootRef = useRef<HTMLDivElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    menuRef.current?.querySelector<HTMLElement>('button:not([disabled])')?.focus();
    const closeOutside = (event: MouseEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) onClose();
    };
    const closeWithKeyboard = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        onClose();
      }
    };
    document.addEventListener('mousedown', closeOutside);
    document.addEventListener('keydown', closeWithKeyboard);
    return () => {
      document.removeEventListener('mousedown', closeOutside);
      document.removeEventListener('keydown', closeWithKeyboard);
    };
  }, [onClose, open]);

  return (
    <div ref={rootRef} className="relative shrink-0">
      <button type="button" aria-haspopup="menu" aria-expanded={open} aria-label={label} title={label} onClick={(event) => { event.stopPropagation(); onToggle(); }} className="flex h-7 w-7 items-center justify-center rounded-md text-gray-400 hover:bg-gray-200 hover:text-gray-800 dark:hover:bg-white/[0.1] dark:hover:text-white">
        <MoreHorizontal size={15} />
      </button>
      {open && (
        <div ref={menuRef} role="menu" className="absolute right-0 top-8 z-50 min-w-40 rounded-lg border border-gray-200 bg-white p-1 shadow-xl dark:border-white/[0.12] dark:bg-[#1a1a1d]">
          {children}
        </div>
      )}
    </div>
  );
}

function MenuItem({ icon, children, danger, disabledReason, onClick }: { icon: ReactNode; children: ReactNode; danger?: boolean; disabledReason?: string; onClick: () => void }) {
  return (
    <button type="button" role="menuitem" disabled={Boolean(disabledReason)} title={disabledReason} onClick={onClick} className={cn('flex w-full items-center gap-2 rounded-md px-2.5 py-2 text-left text-xs hover:bg-gray-100 disabled:cursor-not-allowed disabled:opacity-45 dark:hover:bg-white/[0.08]', danger ? 'text-red-600 dark:text-red-400' : 'text-gray-700 dark:text-gray-200')}>
      {icon}{children}
    </button>
  );
}

export function WorkspaceChatRail(props: Props) {
  const { t } = useTranslation();
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [menuKey, setMenuKey] = useState('');
  const capabilitiesFor = (hostID?: string) => props.capabilitiesByHost[hostID || ''] || props.capabilitiesByHost[''];

  useEffect(() => {
    setExpanded((current) => {
      if (current.size > 0) return current;
      return new Set(props.projects.map((project) => project.id));
    });
  }, [props.projects]);

  const toggleProject = (projectID: string) => {
    setExpanded((current) => {
      const next = new Set(current);
      if (next.has(projectID)) next.delete(projectID); else next.add(projectID);
      return next;
    });
  };

  return (
    <>
      <aside className={cn(
        'absolute inset-y-0 left-0 z-30 flex w-[min(19rem,calc(100vw-3rem))] flex-col border-r border-gray-200 bg-[#f7f7f8] transition-transform dark:border-white/[0.08] dark:bg-[#111113] md:static md:z-auto md:w-[19rem] md:translate-x-0',
        props.open ? 'translate-x-0' : '-translate-x-full',
      )}>
        <div className="flex h-12 shrink-0 items-center justify-between border-b border-gray-200 px-3 dark:border-white/[0.08]">
          <div className="flex min-w-0 items-center gap-2 text-sm font-semibold"><FolderGit2 size={16} /><span className="truncate">{t('workspaceChat.projects', 'Codex App 项目')}</span></div>
          <button type="button" className="rounded-md p-1 hover:bg-gray-200 md:hidden dark:hover:bg-white/[0.08]" onClick={props.onClose} aria-label={t('common.close')}><X size={17} /></button>
        </div>

        <nav className="min-h-0 flex-1 overflow-y-auto p-2" aria-label={t('workspaceChat.projects', 'Codex App 项目')}>
          {props.projects.map((project) => {
            const projectTasks = props.tasks
              .filter((task) => task.project_id === project.id && !task.archived)
              .sort((left, right) => Number(Boolean(right.pinned)) - Number(Boolean(left.pinned)) || (right.modified_at || '').localeCompare(left.modified_at || ''));
            const isExpanded = expanded.has(project.id);
            const projectMenuKey = `project:${project.id}`;
            const projectCapabilities = capabilitiesFor(project.host_id);
            return (
              <section key={project.id} className="mb-1">
                <div className={cn('flex items-center rounded-md', props.selectedProjectID === project.id && 'bg-gray-200/70 dark:bg-white/[0.07]')}>
                  <button type="button" onClick={() => toggleProject(project.id)} aria-expanded={isExpanded} aria-label={`${project.name} 展开任务`} className="flex min-w-0 flex-1 items-center gap-2 px-2 py-2 text-left hover:text-gray-950 dark:hover:text-white">
                    {isExpanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                    <Folder size={15} className="shrink-0 text-amber-500" />
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-sm font-medium text-gray-800 dark:text-gray-100">{project.name}</span>
                      <span className="block truncate text-[10px] text-gray-400">{project.path || project.kind || project.id}</span>
                    </span>
                  </button>
                  {project.kind !== 'unassigned' && (
                    <ActionMenu label={`${project.name} 操作`} open={menuKey === projectMenuKey} onToggle={() => setMenuKey(menuKey === projectMenuKey ? '' : projectMenuKey)} onClose={() => setMenuKey('')}>
                      <MenuItem icon={<Plus size={14} />} disabledReason={projectCapabilities?.create.supported ? undefined : projectCapabilities?.create.reason || '当前 App 未提供创建任务能力'} onClick={() => { setMenuKey(''); props.onNewTask(project); }}>{t('workspaceChat.newTask', '新建任务')}</MenuItem>
                    </ActionMenu>
                  )}
                </div>

                {isExpanded && (
                  <div className="ml-3 border-l border-gray-200 py-1 pl-2 dark:border-white/[0.1]">
                    {projectTasks.map((task) => {
                      const taskMenuKey = `task:${task.id}`;
                      const selected = props.selectedTaskID === task.id;
                      const taskCapabilities = capabilitiesFor(task.host_id || project.host_id);
                      return (
                        <div key={`${task.host_id || ''}:${task.id}`} className={cn('group mb-0.5 flex min-w-0 items-center rounded-md', selected ? 'bg-white text-gray-950 shadow-sm dark:bg-white/[0.1] dark:text-white' : 'text-gray-700 hover:bg-gray-200/70 dark:text-gray-300 dark:hover:bg-white/[0.06]')}>
                          <button type="button" onClick={() => props.onTask(project, task)} aria-label={`打开任务 ${taskLabel(task)}`} className="min-w-0 flex-1 px-2 py-2 text-left">
                            <span className="flex items-center gap-1.5">
                              {task.pinned && <Pin size={11} className="shrink-0 text-amber-500" />}
                              <span className="block truncate text-sm font-medium">{taskLabel(task)}</span>
                            </span>
                            <span className="mt-0.5 flex items-center gap-1.5 text-[10px] text-gray-400">
                              <span className={cn('h-1.5 w-1.5 rounded-full', task.status === 'active' ? 'bg-emerald-500' : task.status === 'systemError' ? 'bg-red-500' : 'bg-gray-400')} />
                              {taskStatus(task.status)}
                            </span>
                          </button>
                          <ActionMenu label={`${taskLabel(task)} 操作`} open={menuKey === taskMenuKey} onToggle={() => setMenuKey(menuKey === taskMenuKey ? '' : taskMenuKey)} onClose={() => setMenuKey('')}>
                            <MenuItem icon={<Pencil size={14} />} disabledReason={taskCapabilities?.rename.supported ? undefined : taskCapabilities?.rename.reason || '当前 App 未提供重命名能力'} onClick={() => { setMenuKey(''); props.onRenameTask(task); }}>重命名</MenuItem>
                            <MenuItem icon={task.pinned ? <PinOff size={14} /> : <Pin size={14} />} disabledReason={taskCapabilities?.pin.supported ? undefined : taskCapabilities?.pin.reason || '当前 App 未提供置顶能力'} onClick={() => { setMenuKey(''); props.onTogglePin(task); }}>{task.pinned ? '取消置顶' : '置顶'}</MenuItem>
                            <MenuItem icon={<Copy size={14} />} onClick={() => { setMenuKey(''); props.onCopyLink(project, task); }}>复制链接</MenuItem>
                            <MenuItem icon={<Archive size={14} />} danger disabledReason={taskCapabilities?.archive.supported ? undefined : taskCapabilities?.archive.reason || '当前 App 未提供归档能力'} onClick={() => { setMenuKey(''); props.onArchiveTask(task); }}>归档</MenuItem>
                          </ActionMenu>
                        </div>
                      );
                    })}
                    {!props.loading && projectTasks.length === 0 && <p className="px-2 py-2 text-xs text-gray-400">{t('workspaceChat.noTasks', '暂无任务')}</p>}
                  </div>
                )}
              </section>
            );
          })}
          {!props.loading && props.projects.length === 0 && <p className="p-4 text-sm leading-6 text-gray-400">{t('workspaceChat.noProjects', '当前 Codex App 没有可用项目')}</p>}
        </nav>
      </aside>
      {props.open && <button type="button" className="absolute inset-0 z-20 bg-black/30 md:hidden" onClick={props.onClose} aria-label={t('common.close')} />}
    </>
  );
}
