import api from './client';

export interface CodexProject {
  device_id: string;
  device_name: string;
  project_id: string;
  project_name: string;
  host_id?: string;
  kind?: string;
  is_git_repository: boolean;
  available: boolean;
  online: boolean;
  reason?: string;
  order: number;
}

export interface CodexTask {
  id: string;
  summary?: string;
  modified_at?: string;
  project_id: string;
  project_name?: string;
  host_id?: string;
  status?: string;
  pinned?: boolean;
  pinned_index?: number;
  archived?: boolean;
}

export interface CodexTaskPage {
  sessions: CodexTask[];
  cursor?: string;
  has_more: boolean;
  total_hint?: number;
}

export interface CodexContentPart {
  type: string;
  text?: string;
}

export interface CodexItem {
  type: 'user_message' | 'agent_message' | 'plan' | 'unsupported' | string;
  id: string;
  content?: CodexContentPart[];
  text?: string;
  status?: string;
  source_type?: string;
  raw_content?: unknown;
}

export interface CodexTurn {
  id: string;
  status?: string;
  started_at?: string;
  completed_at?: string;
  items: CodexItem[];
}

export interface CodexTaskSnapshot {
  task: CodexTask;
  turns: CodexTurn[];
  page: { cursor?: string; has_more: boolean; order: 'oldest_first' };
  wait_cursor?: string;
}

export interface CodexCapability {
  supported: boolean;
  reason?: string;
}

export interface CodexCapabilities {
  create: CodexCapability;
  rename: CodexCapability;
  pin: CodexCapability;
  archive: CodexCapability;
  fork: CodexCapability;
  handoff: CodexCapability;
  interactive_response: CodexCapability;
  automation_mutation: CodexCapability;
}

export interface CodexSearchResult {
  device_id: string;
  task: CodexTask;
}

export interface CodexOfflineDevice {
  device_id: string;
  device_name: string;
  reason: string;
}

export interface CodexAutomation {
  id: string;
  name: string;
  kind: 'heartbeat' | 'cron';
  prompt: string;
  rrule: string;
  status: 'ACTIVE' | 'PAUSED';
  destination?: string;
  execution_environment?: string;
  project_id?: string;
  target_thread_id?: string;
  model?: string;
  reasoning_effort?: string;
  notification_policy?: string;
}

export type CodexAutomationMutation = Omit<CodexAutomation, 'id'>;

export interface CodexPlugin {
  id: string;
  name: string;
  marketplace: string;
  version?: string;
  installed: boolean;
  enabled: boolean;
  install_policy?: string;
  auth_policy?: string;
}

export interface CodexNotification {
  id: number;
  type: string;
  outcome: string;
  occurred_at: string;
  href?: string;
  read: boolean;
}

export interface CodexNotificationPage {
  items: CodexNotification[];
  read_cursor: number;
  unread: number;
}

const resource = (value: string) => encodeURIComponent(value);
const projectTasksPath = (deviceID: string, projectID: string) =>
  `/codex/devices/${resource(deviceID)}/projects/${resource(projectID)}/tasks`;
const taskPath = (deviceID: string, taskID: string) =>
  `/codex/devices/${resource(deviceID)}/tasks/${resource(taskID)}`;

export const listCodexProjects = () => api.get<{ projects: CodexProject[] }>('/codex/projects');

export const listCodexTasks = (deviceID: string, projectID: string, cursor = '', limit = 5) =>
  api.get<CodexTaskPage>(projectTasksPath(deviceID, projectID), {
    limit: String(limit),
    ...(cursor ? { cursor } : {}),
  });

export const createCodexTask = (deviceID: string, projectID: string, prompt: string) =>
  api.post<CodexTask>(projectTasksPath(deviceID, projectID), { prompt, use_local: true });

export const readCodexTask = (deviceID: string, projectID: string, taskID: string, cursor = '', hostID = '', limit = 10) =>
  api.get<CodexTaskSnapshot>(taskPath(deviceID, taskID), {
    project_id: projectID,
    limit: String(limit),
    ...(cursor ? { cursor } : {}),
    ...(hostID ? { host_id: hostID } : {}),
  });

export const waitCodexTask = (deviceID: string, projectID: string, taskID: string, cursor = '', hostID = '', timeoutMS = 30_000) =>
  api.get<CodexTaskSnapshot>(`${taskPath(deviceID, taskID)}/wait`, {
    project_id: projectID,
    timeout_ms: String(timeoutMS),
    ...(cursor ? { cursor } : {}),
    ...(hostID ? { host_id: hostID } : {}),
  });

export const postCodexMessage = (deviceID: string, projectID: string, taskID: string, prompt: string, hostID = '') =>
  api.request('POST', `${taskPath(deviceID, taskID)}/messages`, { prompt }, {
    project_id: projectID,
    ...(hostID ? { host_id: hostID } : {}),
  });

export const patchCodexTask = (deviceID: string, projectID: string, taskID: string, patch: { title?: string; pinned?: boolean; archived?: boolean }, hostID = '') =>
  api.request('PATCH', taskPath(deviceID, taskID), patch, {
    project_id: projectID,
    ...(hostID ? { host_id: hostID } : {}),
  });

export const getCodexCapabilities = (deviceID: string) =>
  api.get<CodexCapabilities>(`/codex/devices/${resource(deviceID)}/capabilities`);

export const searchCodexTasks = (query: string, limit = 40) =>
  api.get<{ results: CodexSearchResult[]; offline_devices: CodexOfflineDevice[] }>('/codex/search', { q: query, limit: String(limit) });

const deviceResource = (deviceID: string, name: string) =>
  `/codex/devices/${resource(deviceID)}/${name}`;

export const listCodexAutomations = (deviceID: string) =>
  api.get<{ automations: CodexAutomation[] }>(deviceResource(deviceID, 'automations'));

export const createCodexAutomation = (deviceID: string, mutation: CodexAutomationMutation) =>
  api.post<CodexAutomation>(deviceResource(deviceID, 'automations'), mutation);

export const updateCodexAutomation = (deviceID: string, automationID: string, mutation: Partial<CodexAutomationMutation>) =>
  api.patch<CodexAutomation>(`${deviceResource(deviceID, 'automations')}/${resource(automationID)}`, mutation);

export const deleteCodexAutomation = (deviceID: string, automationID: string) =>
  api.delete<{ deleted: boolean }>(`${deviceResource(deviceID, 'automations')}/${resource(automationID)}`);

export const listCodexPlugins = (deviceID: string, available = true) =>
  api.get<{ plugins: CodexPlugin[] }>(deviceResource(deviceID, 'plugins'), { available: String(available) });

export const installCodexPlugin = (deviceID: string, pluginID: string) =>
  api.post<CodexPlugin>(`${deviceResource(deviceID, 'plugins')}/${resource(pluginID)}/install`);

export const removeCodexPlugin = (deviceID: string, pluginID: string) =>
  api.delete<{ removed: boolean }>(`${deviceResource(deviceID, 'plugins')}/${resource(pluginID)}`);

export const listArchivedCodexTasks = (deviceID: string, limit = 50) =>
  api.get<CodexTaskPage>(deviceResource(deviceID, 'archived-tasks'), { limit: String(limit) });

export const restoreArchivedCodexTask = (deviceID: string, taskID: string, hostID = '') =>
  api.request<{ restored: boolean }>('PATCH', `${deviceResource(deviceID, 'archived-tasks')}/${resource(taskID)}`, undefined, hostID ? { host_id: hostID } : undefined);

export const listCodexNotifications = (after = 0, limit = 30) =>
  api.get<CodexNotificationPage>('/notifications', { after: String(after), limit: String(limit) });

export const markCodexNotificationsRead = (throughID: number) =>
  api.post<{ read_cursor: number }>('/notifications/read', { through_id: throughID });
