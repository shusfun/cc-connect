import api from './client';

export interface LastMessage {
  role: string;
  content: string;
  timestamp: string;
}

export interface Session {
  id: string;
  session_key: string;
  name: string;
  platform: string;
  agent_type: string;
  active: boolean;
  live: boolean;
  created_at: string;
  updated_at: string;
  history_count: number;
  last_message: LastMessage | null;
  user_name?: string;
  chat_name?: string;
}

export interface SessionDetail extends Session {
  agent_session_id: string;
  history: AgentTaskHistoryEntry[];
}

export interface AgentProject {
  id: string;
  name: string;
  path?: string;
  host_id?: string;
  kind?: string;
  is_git_repository: boolean;
}

export interface AgentTask {
  id: string;
  summary?: string;
  message_count?: number;
  modified_at?: string;
  git_branch?: string;
  project_id?: string;
  project_name?: string;
  cwd?: string;
  host_id?: string;
  status?: string;
  pinned?: boolean;
  pinned_index?: number;
  archived?: boolean;
}

export interface AgentTaskHistoryEntry {
  role: 'user' | 'assistant' | string;
  content: string;
  timestamp: string;
}

export interface AgentTaskSnapshot {
  session: AgentTask;
  history: AgentTaskHistoryEntry[];
  cursor?: string;
  wait_cursor?: string;
  has_more: boolean;
}

export interface AgentTaskMetadataPatch {
  title?: string;
  pinned?: boolean;
  archived?: boolean;
}

export interface AgentCapability {
  supported: boolean;
  reason?: string;
}

export interface AgentSessionCapabilities {
  create: AgentCapability;
  rename: AgentCapability;
  pin: AgentCapability;
  archive: AgentCapability;
  fork: AgentCapability;
  handoff: AgentCapability;
  interactive_response: AgentCapability;
}

const projectPath = (project: string) => `/projects/${encodeURIComponent(project)}`;
const taskPath = (project: string, taskID: string) => `${projectPath(project)}/sessions/${encodeURIComponent(taskID)}`;

export const listSessions = (project: string) =>
  api.get<{ sessions: Session[]; active_keys?: Record<string, string>; authoritative?: boolean }>(`${projectPath(project)}/sessions`);

export const getSession = (project: string, id: string, historyLimit?: number, hostID?: string, cursor?: string) =>
  api.get<SessionDetail>(taskPath(project, id), {
    ...(historyLimit ? { history_limit: String(historyLimit) } : {}),
    ...(hostID ? { host_id: hostID } : {}),
    ...(cursor ? { cursor } : {}),
  });

export const listAgentTasks = (project: string) =>
  api.get<{ sessions: AgentTask[]; authoritative: boolean }>(`${projectPath(project)}/sessions`);

export const getAgentTask = (project: string, id: string, historyLimit?: number, hostID?: string, cursor?: string) =>
  api.get<AgentTaskSnapshot>(taskPath(project, id), {
    ...(historyLimit ? { history_limit: String(historyLimit) } : {}),
    ...(hostID ? { host_id: hostID } : {}),
    ...(cursor ? { cursor } : {}),
  });

export const createSession = (project: string, body: { session_key: string; name?: string; project_id?: string; prompt?: string; use_local?: boolean }) =>
  api.post<{ session?: AgentTask; session_key?: string }>(`${projectPath(project)}/sessions`, body);

export const deleteSession = (project: string, id: string, hostID?: string) =>
  api.request('DELETE', taskPath(project, id), undefined, hostID ? { host_id: hostID } : undefined);

export const updateSessionMetadata = (project: string, id: string, patch: AgentTaskMetadataPatch, hostID?: string) =>
  api.request('PATCH', taskPath(project, id), patch, hostID ? { host_id: hostID } : undefined);

export const switchSession = (project: string, body: { session_key: string; session_id: string }) =>
  api.post(`${projectPath(project)}/sessions/switch`, body);

export const sendMessage = (project: string, body: { session_key: string; message: string }) =>
  api.post(`${projectPath(project)}/send`, body);

export const listAgentProjects = (project: string) =>
  api.get<{ projects: AgentProject[] }>(`${projectPath(project)}/agent-projects`);

export const getAgentCapabilities = (project: string, hostID?: string) =>
  api.get<{ capabilities: AgentSessionCapabilities }>(`${projectPath(project)}/agent-capabilities`, hostID ? { host_id: hostID } : undefined);
