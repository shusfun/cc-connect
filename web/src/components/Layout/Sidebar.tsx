import { useEffect, useMemo, useState } from 'react';
import { NavLink, useNavigate, useParams } from 'react-router-dom';
import {
  Archive, Blocks, CalendarClock, ChevronDown, ChevronLeft, ChevronRight, CircleUserRound,
  Folder, Loader2, LogOut, MessageSquarePlus, MoreHorizontal, Pin, PinOff, Search, Settings, X,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { getAdministratorProfile, getCodexCapabilities, patchCodexTask, type AdministratorProfile, type CodexCapabilities, type CodexProject, type CodexTask } from '@/api';
import { useCodexWorkspace } from '@/pages/Chat/CodexWorkspaceContext';
import { useFeedback } from '@/components/ui';
import { useAuthStore } from '@/store/auth';
import SearchPalette from './SearchPalette';
import NotificationPopover from './NotificationPopover';
import { useTranslation } from 'react-i18next';

type SidebarProps = { mobileOpen: boolean; onMobileClose: () => void };

const taskLabel = (task: CodexTask) => task.summary?.trim() || task.id.slice(0, 12);
const taskHref = (project: CodexProject, taskID: string) =>
  `/tasks/${encodeURIComponent(project.device_id)}/${encodeURIComponent(project.project_id)}/${encodeURIComponent(taskID)}`;

export default function Sidebar({ mobileOpen, onMobileClose }: SidebarProps) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const params = useParams<{ deviceID?: string; projectID?: string; taskID?: string }>();
  const logout = useAuthStore((state) => state.logout);
  const { notify } = useFeedback();
  const workspace = useCodexWorkspace();
  const [collapsed, setCollapsed] = useState(false);
  const [expandedProjects, setExpandedProjects] = useState<Set<string>>(new Set());
  const [menuTask, setMenuTask] = useState('');
  const [accountOpen, setAccountOpen] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [profile, setProfile] = useState<AdministratorProfile | null>(null);
  const [capabilities, setCapabilities] = useState<Record<string, CodexCapabilities>>({});
  const deviceIDs = useMemo(() => [...new Set(workspace.projects.filter((project) => project.online).map((project) => project.device_id))], [workspace.projects]);

  useEffect(() => {
    setExpandedProjects((current) => current.size > 0 ? current : new Set(workspace.projects.map(workspace.keyFor)));
  }, [workspace.keyFor, workspace.projects]);
  useEffect(() => { getAdministratorProfile().then(setProfile).catch(() => undefined); }, []);
  useEffect(() => {
    let cancelled = false;
    void Promise.all(deviceIDs.map(async (deviceID) => [deviceID, await getCodexCapabilities(deviceID)] as const)).then((entries) => {
      if (!cancelled) setCapabilities(Object.fromEntries(entries));
    }).catch(() => {
      if (!cancelled) setCapabilities({});
    });
    return () => { cancelled = true; };
  }, [deviceIDs]);
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault();
        setSearchOpen(true);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  const selectedProject = workspace.projects.find((project) =>
    project.device_id === params.deviceID && project.project_id === params.projectID);
  const createProject = selectedProject || workspace.projects.find((project) => project.online && project.available);

  const openNewTask = () => {
    if (!createProject) return;
    navigate(taskHref(createProject, 'new'));
    onMobileClose();
  };

  const mutate = async (project: CodexProject, task: CodexTask, patch: { pinned?: boolean; archived?: boolean }) => {
    setMenuTask('');
    try {
      await patchCodexTask(project.device_id, project.project_id, task.id, patch, task.host_id);
      if (patch.archived) workspace.removeTask(project, task.id, task.host_id);
      else workspace.upsertTask(project, { ...task, ...patch });
    } catch (cause) {
      notify(cause instanceof Error ? cause.message : String(cause), 'error');
    }
  };

  const navItemClass = ({ isActive }: { isActive: boolean }) => cn(
    'flex h-9 min-w-0 items-center gap-2 rounded-md px-2 text-sm hover:bg-black/[0.05] dark:hover:bg-white/[0.06]',
    isActive && 'bg-black/[0.06] dark:bg-white/[0.08]', collapsed && 'md:justify-center',
  );

  return (
    <>
      <aside aria-label={t('codex.workspaceNavigation')} className={cn(
        'fixed inset-y-0 left-0 z-40 flex h-dvh min-h-0 flex-col border-r border-black/[0.08] bg-[#f4f4f1] transition-[transform,width] duration-200 dark:border-white/[0.08] dark:bg-[#1d1d1b]',
        mobileOpen ? 'translate-x-0' : '-translate-x-full', 'md:static md:z-auto md:translate-x-0',
        collapsed ? 'w-[min(18rem,calc(100vw-2.5rem))] md:w-14' : 'w-[min(18rem,calc(100vw-2.5rem))] md:w-72',
      )}>
        <div className="flex h-12 shrink-0 items-center gap-1 px-2">
          <button type="button" onClick={() => setAccountOpen((value) => !value)} className={cn('flex h-8 min-w-0 flex-1 items-center gap-2 rounded-md px-2 text-left hover:bg-black/[0.05] dark:hover:bg-white/[0.06]', collapsed && 'md:justify-center')} aria-expanded={accountOpen}>
            <span className="grid h-5 w-5 shrink-0 place-items-center rounded bg-gray-950 text-[11px] font-semibold text-white dark:bg-white dark:text-gray-950">C</span>
            <span className={cn('truncate text-sm font-semibold', collapsed && 'md:hidden')}>CC-Connect</span>
            <ChevronDown size={13} className={cn('ml-auto text-gray-400', collapsed && 'md:hidden')} />
          </button>
          <button type="button" onClick={() => setSearchOpen(true)} className={cn('grid h-8 w-8 shrink-0 place-items-center rounded-md text-gray-500 hover:bg-black/[0.05] dark:text-gray-400 dark:hover:bg-white/[0.06]', collapsed && 'md:hidden')} aria-label={t('common.search')}><Search size={16} /></button>
          <div className={cn(collapsed && 'md:hidden')}><NotificationPopover /></div>
          <button type="button" onClick={onMobileClose} className="grid h-8 w-8 place-items-center rounded-md md:hidden" aria-label={t('codex.closeNavigation')}><X size={17} /></button>
        </div>

        <nav className="shrink-0 space-y-0.5 px-2" aria-label={t('codex.workspaceActions')}>
          <button type="button" onClick={openNewTask} disabled={!createProject} className={cn('flex h-9 w-full min-w-0 items-center gap-2 rounded-md px-2 text-sm hover:bg-black/[0.05] disabled:opacity-40 dark:hover:bg-white/[0.06]', collapsed && 'md:justify-center')} title={t('codex.newTask')}><MessageSquarePlus size={16} className="shrink-0" /><span className={cn('truncate', collapsed && 'md:hidden')}>{t('codex.newTask')}</span></button>
          <NavLink to="/scheduled" onClick={onMobileClose} className={navItemClass} title={t('codex.scheduled.title')}><CalendarClock size={16} className="shrink-0" /><span className={cn('truncate', collapsed && 'md:hidden')}>{t('codex.scheduled.title')}</span></NavLink>
          <NavLink to="/plugins" onClick={onMobileClose} className={navItemClass} title={t('codex.plugins.title')}><Blocks size={16} className="shrink-0" /><span className={cn('truncate', collapsed && 'md:hidden')}>{t('codex.plugins.title')}</span></NavLink>
        </nav>

        <div className={cn('mt-4 min-h-0 flex-1 overflow-y-auto px-2 pb-3', collapsed && 'md:hidden')}>
          <div className="mb-1 px-2 text-[11px] font-medium text-gray-400">{t('codex.projects')}</div>
          {workspace.loading && <div className="grid h-24 place-items-center"><Loader2 size={18} className="animate-spin text-gray-400" /></div>}
          {!workspace.loading && workspace.error && <p role="alert" className="px-2 py-3 text-xs leading-5 text-red-600 dark:text-red-400">{workspace.error}</p>}
          {!workspace.loading && !workspace.error && workspace.projects.length === 0 && <p className="px-2 py-3 text-xs leading-5 text-gray-500">{t('codex.noProjects')}</p>}
          {workspace.projects.map((project) => <ProjectTasks key={workspace.keyFor(project)} project={project} selected={project.device_id === params.deviceID && project.project_id === params.projectID} selectedTaskID={params.taskID || ''} open={expandedProjects.has(workspace.keyFor(project))} toggle={() => setExpandedProjects((current) => {
            const next = new Set(current); const key = workspace.keyFor(project); if (next.has(key)) next.delete(key); else next.add(key); return next;
          })} menuTask={menuTask} setMenuTask={setMenuTask} mutate={mutate} capabilities={capabilities[project.device_id]} onMobileClose={onMobileClose} />)}
        </div>

        <div className="relative shrink-0 border-t border-black/[0.08] p-2 dark:border-white/[0.08]">
          {accountOpen && <div className="absolute bottom-12 left-2 right-2 z-50 rounded-lg border border-black/10 bg-white p-1 shadow-xl dark:border-white/10 dark:bg-[#252523]"><button type="button" onClick={() => { setAccountOpen(false); navigate('/settings/general'); }} className="flex h-9 w-full items-center gap-2 rounded-md px-2 text-sm hover:bg-black/[0.05] dark:hover:bg-white/[0.07]"><Settings size={15} />{t('nav.settings')}</button><button type="button" onClick={() => void logout()} className="flex h-9 w-full items-center gap-2 rounded-md px-2 text-sm text-red-600 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-950/30"><LogOut size={15} />{t('login.logout')}</button></div>}
          <div className="flex items-center gap-1"><button type="button" onClick={() => setAccountOpen((value) => !value)} className={cn('flex h-9 min-w-0 flex-1 items-center gap-2 rounded-md px-2 text-left hover:bg-black/[0.05] dark:hover:bg-white/[0.06]', collapsed && 'md:justify-center')} aria-label={t('codex.accountMenu')} aria-expanded={accountOpen}><CircleUserRound size={17} className="shrink-0" /><span className={cn('truncate text-sm', collapsed && 'md:hidden')}>{profile?.username || t('settings.account')}</span></button><button type="button" onClick={() => setCollapsed((value) => !value)} className="hidden h-8 w-8 shrink-0 place-items-center rounded-md text-gray-400 hover:bg-black/[0.05] md:grid dark:hover:bg-white/[0.06]" aria-label={collapsed ? t('codex.expandSidebar') : t('codex.collapseSidebar')}>{collapsed ? <ChevronRight size={17} /> : <ChevronLeft size={17} />}</button></div>
        </div>
      </aside>
      {mobileOpen && <button type="button" className="fixed inset-0 z-30 bg-black/35 md:hidden" onClick={onMobileClose} aria-label={t('codex.closeNavigation')} />}
      <SearchPalette open={searchOpen} onClose={() => setSearchOpen(false)} />
    </>
  );
}

type ProjectTasksProps = {
  project: CodexProject; selected: boolean; selectedTaskID: string; open: boolean; toggle: () => void;
  menuTask: string; setMenuTask: (value: string) => void;
  mutate: (project: CodexProject, task: CodexTask, patch: { pinned?: boolean; archived?: boolean }) => Promise<void>;
  capabilities?: CodexCapabilities;
  onMobileClose: () => void;
};

function ProjectTasks({ project, selected, selectedTaskID, open, toggle, menuTask, setMenuTask, mutate, capabilities, onMobileClose }: ProjectTasksProps) {
  const { t } = useTranslation();
  const workspace = useCodexWorkspace();
  const key = workspace.keyFor(project);
  const page = workspace.pages[key];
  const tasks = (page?.expanded ? page.tasks : page?.tasks.slice(0, 5)) || [];
  return <section className="mb-1">
    <button type="button" aria-expanded={open} aria-label={t(open ? 'codex.collapseProject' : 'codex.expandProject', { name: project.project_name })} onClick={toggle} className={cn('flex w-full min-w-0 items-center gap-2 rounded-md px-2 py-2 text-left hover:bg-black/[0.05] dark:hover:bg-white/[0.06]', selected && 'bg-black/[0.05] dark:bg-white/[0.06]')}>{open ? <ChevronDown size={13} /> : <ChevronRight size={13} />}<Folder size={15} className="shrink-0 text-gray-500" /><span className="min-w-0 flex-1 truncate text-sm font-medium">{project.project_name}</span>{(!project.online || !project.available) && <span className="h-2 w-2 shrink-0 rounded-full bg-red-500" title={project.reason || t('codex.runtimeOffline')} />}</button>
    {open && <div className="ml-3 border-l border-black/[0.09] pl-2 dark:border-white/[0.09]">
      {tasks.map((task) => {
        const menuKey = `${key}\u0000${task.host_id || ''}\u0000${task.id}`;
        const pinSupported = capabilities?.pin.supported === true;
        const archiveSupported = capabilities?.archive.supported === true;
        return <div key={menuKey} className={cn('group relative mb-0.5 flex min-w-0 items-center rounded-md', selected && selectedTaskID === task.id ? 'bg-white shadow-sm dark:bg-white/[0.1]' : 'hover:bg-black/[0.05] dark:hover:bg-white/[0.06]')}><NavLink to={taskHref(project, task.id)} onClick={onMobileClose} className="min-w-0 flex-1 px-2 py-1.5"><span className="flex min-w-0 items-center gap-1.5">{task.pinned && <Pin size={11} className="shrink-0" />}<span className="truncate text-[13px]">{taskLabel(task)}</span></span></NavLink><button type="button" onClick={() => setMenuTask(menuTask === menuKey ? '' : menuKey)} className="mr-1 grid h-7 w-7 shrink-0 place-items-center rounded-md text-gray-400 opacity-0 hover:bg-black/[0.06] group-hover:opacity-100 focus:opacity-100 dark:hover:bg-white/[0.08]" aria-label={t('codex.taskActions', { name: taskLabel(task) })}><MoreHorizontal size={14} /></button>{menuTask === menuKey && <div role="menu" className="absolute right-1 top-8 z-50 min-w-40 rounded-md border border-gray-200 bg-white p-1 shadow-xl dark:border-white/[0.12] dark:bg-[#222220]"><button role="menuitem" type="button" disabled={!pinSupported} title={!pinSupported ? capabilities?.pin.reason || t('codex.unavailable') : undefined} onClick={() => void mutate(project, task, { pinned: !task.pinned })} className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-xs hover:bg-gray-100 disabled:opacity-45 dark:hover:bg-white/[0.08]">{task.pinned ? <PinOff size={13} /> : <Pin size={13} />}<span className="flex-1 text-left">{task.pinned ? t('codex.unpin') : t('codex.pin')}</span>{!pinSupported && <span>{t('codex.unavailable')}</span>}</button><button role="menuitem" type="button" disabled={!archiveSupported} title={!archiveSupported ? capabilities?.archive.reason || t('codex.unavailable') : undefined} onClick={() => void mutate(project, task, { archived: true })} className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-xs text-red-600 hover:bg-red-50 disabled:opacity-45 dark:text-red-400 dark:hover:bg-red-950/30"><Archive size={13} /><span className="flex-1 text-left">{t('codex.archive')}</span>{!archiveSupported && <span>{t('codex.unavailable')}</span>}</button></div>}</div>;
      })}
      {page?.error && <p className="px-2 py-1.5 text-[11px] text-red-600 dark:text-red-400">{page.error}</p>}
      {!page?.loading && tasks.length === 0 && !page?.error && <p className="px-2 py-1.5 text-[11px] text-gray-400">{t('codex.noTasks')}</p>}
      {(page?.hasMore || (page?.expanded && page.tasks.length > 5)) && <button type="button" disabled={page.loading} onClick={() => page.expanded ? workspace.showLess(project) : void workspace.loadMore(project)} className="flex w-full items-center gap-1 px-2 py-1.5 text-[11px] text-gray-500 hover:text-gray-950 disabled:opacity-50 dark:hover:text-white">{page.loading && <Loader2 size={11} className="animate-spin" />}{page.expanded ? t('codex.showLess') : t('codex.showMore')}</button>}
    </div>}
  </section>;
}
