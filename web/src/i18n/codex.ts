const en = {
  workspaceNavigation: 'Workspace navigation', workspaceActions: 'Workspace actions', closeNavigation: 'Close navigation', openNavigation: 'Open navigation',
  newTask: 'New task', projects: 'Projects', noProjects: 'No Codex projects are available', accountMenu: 'Account menu', expandSidebar: 'Expand sidebar', collapseSidebar: 'Collapse sidebar',
  collapseProject: 'Collapse tasks in {{name}}', expandProject: 'Expand tasks in {{name}}', runtimeOffline: 'Runtime offline', taskActions: 'Actions for {{name}}',
  unpin: 'Unpin', pin: 'Pin', archive: 'Archive', unavailable: 'Unavailable', noTasks: 'No tasks', showLess: 'Show less', showMore: 'Show more', device: 'Codex device', create: 'Create',
  noAvailableProjects: 'No Codex projects are currently available', noSelectedTask: 'No task selected', emptyTask: 'This task has no content yet', backToBottom: 'Back to bottom',
  newTaskPlaceholder: 'Describe the task for Codex', messagePlaceholder: 'Send a message to Codex', send: 'Send', plan: 'Plan', unsupportedItem: 'Unsupported Codex item: {{type}}',
  status: { inProgress: 'In progress', pending: 'Pending', completed: 'Completed', cancelled: 'Cancelled', failed: 'Error', unknown: 'Unknown status' },
  search: { title: 'Search tasks', placeholder: 'Search projects and tasks', close: 'Close search', minimum: 'Enter at least two characters', empty: 'No matching tasks' },
  notifications: { title: 'Notifications', readAll: 'Mark all read', empty: 'No notifications', events: { runtime_connected: 'Codex Runtime connected', runtime_disconnected: 'Codex Runtime offline', device_paired: 'New device paired', device_revoked: 'Device revoked', task_completed: 'Task completed', task_failed: 'Task failed', deploy_completed: 'Update completed', runtime_update_completed: 'Update completed', deploy_failed: 'Update failed', runtime_update_failed: 'Update failed', default: 'CC-Connect status updated' } },
  scheduled: {
    title: 'Scheduled', subtitle: 'Managed by Codex App on the selected device', deleteTitle: 'Delete scheduled task', deleteMessage: 'Delete "{{name}}"?',
    name: 'Name', kind: 'Type', cron: 'Standalone task', heartbeat: 'Task follow-up', rrule: 'Schedule rule', anyProject: 'Any project', targetTask: 'Target task', selectTask: 'Select a task',
    prompt: 'Instructions', empty: 'No scheduled tasks', active: 'Active', paused: 'Paused', pauseTask: 'Pause {{name}}', resumeTask: 'Resume {{name}}', deleteTask: 'Delete {{name}}', targetTasksError: 'Could not load target tasks: {{error}}', invalidTaskCursor: 'Codex returned an invalid task cursor', mutationUnavailable: 'This Codex App version does not provide scheduled task editing.',
  },
  plugins: {
    title: 'Plugins', subtitle: 'Official plugin catalog from the selected Codex device', empty: 'No plugins in this catalog', removeTitle: 'Remove plugin', removeMessage: 'Remove "{{name}}" from this device?',
    remove: 'Remove', removeNamed: 'Remove {{name}}', installNamed: 'Install {{name}}', installed: 'Installed', available: 'Available', enabled: 'Enabled',
  },
  archived: { title: 'Archived tasks', subtitle: 'View and restore tasks archived in Codex App', empty: 'No archived tasks', restore: 'Restore', restored: 'Task restored', viewNamed: 'View {{name}}' },
  settings: {
    navigation: 'Settings navigation', back: 'Back to app', closeNavigation: 'Close settings navigation', openNavigation: 'Open settings navigation', search: 'Search settings...', groups: 'Settings groups', noMatch: 'No matching settings',
    personal: 'Personal', connections: 'Connections', system: 'System', archive: 'Archive', general: 'General', appearance: 'Appearance', account: 'Account', devices: 'Devices', feishu: 'Feishu', updates: 'Updates', runtime: 'Runtime', archived: 'Archived tasks',
    generalKeywords: 'language attachments idle timeout display', appearanceKeywords: 'theme colors dark light', accountKeywords: 'password sign out administrator', devicesKeywords: 'pair runtime online logs', feishuKeywords: 'app id secret permissions', updatesKeywords: 'version release rollback', runtimeKeywords: 'service configuration restart logs', archivedKeywords: 'restore chat tasks',
  },
  feishu: {
    subtitle: 'Configure the China-region Feishu WebSocket connection and allowed users', saved: 'Saved. Restart the service to apply the Feishu connection settings.',
    enable: 'Enable Feishu', enableHint: 'Receive and reply to Codex tasks through the Feishu long connection', secretConfigured: 'Configured; leave blank to keep it', secretPlaceholder: 'Enter App Secret',
    allowedUsers: 'Allowed users', allowedUsersPlaceholder: 'Comma-separated user IDs', allowedUsersHint: 'Blank allows nobody; use * to allow all users.',
  },
};

const zh = {
  workspaceNavigation: '工作区导航', workspaceActions: '工作区功能', closeNavigation: '关闭导航', openNavigation: '打开导航',
  newTask: '新任务', projects: '项目', noProjects: '当前没有 Codex 项目', accountMenu: '账户菜单', expandSidebar: '展开侧栏', collapseSidebar: '收起侧栏',
  collapseProject: '收起 {{name}} 的任务', expandProject: '展开 {{name}} 的任务', runtimeOffline: 'Runtime 离线', taskActions: '{{name}} 操作',
  unpin: '取消置顶', pin: '置顶', archive: '归档', unavailable: '不可用', noTasks: '暂无任务', showLess: '显示更少', showMore: '显示更多', device: 'Codex 设备', create: '新建',
  noAvailableProjects: '当前没有可用的 Codex 项目', noSelectedTask: '没有选中的任务', emptyTask: '当前任务还没有内容', backToBottom: '回到底部',
  newTaskPlaceholder: '描述你要 Codex 完成的任务', messagePlaceholder: '给 Codex 发送消息', send: '发送', plan: '计划', unsupportedItem: '暂不支持的 Codex item：{{type}}',
  status: { inProgress: '进行中', pending: '待处理', completed: '已完成', cancelled: '已取消', failed: '发生错误', unknown: '状态未知' },
  search: { title: '搜索任务', placeholder: '搜索项目和任务', close: '关闭搜索', minimum: '输入至少两个字符', empty: '没有匹配的任务' },
  notifications: { title: '通知', readAll: '全部已读', empty: '暂无通知', events: { runtime_connected: 'Codex Runtime 已连接', runtime_disconnected: 'Codex Runtime 已离线', device_paired: '新设备已配对', device_revoked: '设备已撤销', task_completed: '任务已完成', task_failed: '任务执行失败', deploy_completed: '更新已完成', runtime_update_completed: '更新已完成', deploy_failed: '更新失败', runtime_update_failed: '更新失败', default: 'CC-Connect 状态已更新' } },
  scheduled: {
    title: '已安排', subtitle: '由所选设备上的 Codex App 管理', deleteTitle: '删除已安排任务', deleteMessage: '确定删除“{{name}}”吗？',
    name: '名称', kind: '类型', cron: '独立任务', heartbeat: '任务跟进', rrule: '计划规则', anyProject: '不限定项目', targetTask: '目标任务', selectTask: '选择任务',
    prompt: '执行内容', empty: '没有已安排任务', active: '运行中', paused: '已暂停', pauseTask: '暂停 {{name}}', resumeTask: '恢复 {{name}}', deleteTask: '删除 {{name}}', targetTasksError: '无法加载目标任务：{{error}}', invalidTaskCursor: 'Codex 返回了无效的任务游标', mutationUnavailable: '当前 Codex App 版本不提供已安排任务编辑能力。',
  },
  plugins: {
    title: '插件', subtitle: '来自所选 Codex 设备的官方插件目录', empty: '当前目录没有插件', removeTitle: '移除插件', removeMessage: '从此设备移除“{{name}}”吗？',
    remove: '移除', removeNamed: '移除 {{name}}', installNamed: '安装 {{name}}', installed: '已安装', available: '可安装', enabled: '已启用',
  },
  archived: { title: '已归档任务', subtitle: '查看并恢复 Codex App 中已归档的任务', empty: '没有已归档任务', restore: '恢复', restored: '任务已恢复', viewNamed: '查看 {{name}}' },
  settings: {
    navigation: '设置导航', back: '返回应用', closeNavigation: '关闭设置导航', openNavigation: '打开设置导航', search: '搜索设置...', groups: '设置分组', noMatch: '没有匹配的设置',
    personal: '个人', connections: '连接', system: '系统', archive: '归档', general: '常规', appearance: '外观', account: '账户', devices: '设备', feishu: '飞书', updates: '更新', runtime: 'Runtime', archived: '已归档任务',
    generalKeywords: '语言 附件 空闲 超时 显示', appearanceKeywords: '主题 颜色 深色 浅色', accountKeywords: '密码 退出 管理员', devicesKeywords: '配对 Runtime 在线 日志', feishuKeywords: 'App ID Secret 权限', updatesKeywords: '版本 发布 回滚', runtimeKeywords: '服务 配置 重启 日志', archivedKeywords: '恢复 聊天 任务',
  },
  feishu: {
    subtitle: '配置中国区 Feishu WebSocket 连接和允许发送任务的用户', saved: '已保存。重启服务后飞书连接配置生效。',
    enable: '启用飞书', enableHint: '通过飞书长连接接收和回复 Codex 任务', secretConfigured: '已配置，留空保持不变', secretPlaceholder: '输入 App Secret',
    allowedUsers: '允许用户', allowedUsersPlaceholder: '用户 ID，多个值以逗号分隔', allowedUsersHint: '留空表示不允许任何用户，使用 * 表示允许所有用户。',
  },
};

const zhTW = {
  ...zh,
  workspaceNavigation: '工作區導覽', workspaceActions: '工作區功能', closeNavigation: '關閉導覽', openNavigation: '開啟導覽', projects: '專案', noProjects: '目前沒有 Codex 專案',
  noAvailableProjects: '目前沒有可用的 Codex 專案', noSelectedTask: '沒有選取的任務', emptyTask: '目前任務尚無內容', showLess: '顯示較少', showMore: '顯示更多',
  search: { title: '搜尋任務', placeholder: '搜尋專案和任務', close: '關閉搜尋', minimum: '請輸入至少兩個字元', empty: '沒有相符的任務' },
  notifications: { ...zh.notifications, title: '通知', readAll: '全部標為已讀', empty: '暫無通知' },
  archived: { title: '已封存任務', subtitle: '檢視並還原 Codex App 中已封存的任務', empty: '沒有已封存任務', restore: '還原', restored: '任務已還原', viewNamed: '檢視 {{name}}' },
};

const ja = {
  ...en,
  workspaceNavigation: 'ワークスペースナビゲーション', workspaceActions: 'ワークスペース操作', closeNavigation: 'ナビゲーションを閉じる', openNavigation: 'ナビゲーションを開く', newTask: '新しいタスク', projects: 'プロジェクト', noProjects: 'Codex プロジェクトがありません',
  noAvailableProjects: '利用可能な Codex プロジェクトがありません', noSelectedTask: 'タスクが選択されていません', emptyTask: 'このタスクにはまだ内容がありません', backToBottom: '一番下へ戻る', send: '送信', plan: '計画',
  search: { title: 'タスクを検索', placeholder: 'プロジェクトとタスクを検索', close: '検索を閉じる', minimum: '2文字以上入力してください', empty: '一致するタスクはありません' },
  notifications: { ...en.notifications, title: '通知', readAll: 'すべて既読', empty: '通知はありません', events: { runtime_connected: 'Codex Runtime が接続されました', runtime_disconnected: 'Codex Runtime がオフラインです', device_paired: '新しいデバイスがペアリングされました', device_revoked: 'デバイスが取り消されました', task_completed: 'タスクが完了しました', task_failed: 'タスクに失敗しました', deploy_completed: '更新が完了しました', runtime_update_completed: '更新が完了しました', deploy_failed: '更新に失敗しました', runtime_update_failed: '更新に失敗しました', default: 'CC-Connect の状態が更新されました' } },
  scheduled: { ...en.scheduled, title: 'スケジュール', subtitle: '選択したデバイスの Codex App で管理', name: '名前', kind: '種類', cron: '独立タスク', heartbeat: 'タスクのフォローアップ', rrule: 'スケジュール規則', targetTask: '対象タスク', selectTask: 'タスクを選択', prompt: '実行内容', empty: 'スケジュールされたタスクはありません', active: '実行中', paused: '一時停止' },
  plugins: { ...en.plugins, title: 'プラグイン', subtitle: '選択した Codex デバイスの公式プラグインカタログ', empty: 'プラグインはありません', installed: 'インストール済み', available: '利用可能', enabled: '有効' },
  archived: { ...en.archived, title: 'アーカイブ済みタスク', subtitle: 'Codex App でアーカイブしたタスクを表示・復元', empty: 'アーカイブ済みタスクはありません', restore: '復元', restored: 'タスクを復元しました' },
  settings: { ...en.settings, navigation: '設定ナビゲーション', back: 'アプリに戻る', search: '設定を検索...', noMatch: '一致する設定はありません', personal: '個人', connections: '接続', system: 'システム', archive: 'アーカイブ', general: '一般', appearance: '外観', account: 'アカウント', devices: 'デバイス', feishu: 'Feishu', updates: '更新', archived: 'アーカイブ済みタスク' },
};

const es = {
  ...en,
  workspaceNavigation: 'Navegacion del espacio de trabajo', workspaceActions: 'Acciones del espacio de trabajo', closeNavigation: 'Cerrar navegacion', openNavigation: 'Abrir navegacion', newTask: 'Nueva tarea', projects: 'Proyectos', noProjects: 'No hay proyectos de Codex',
  noAvailableProjects: 'No hay proyectos de Codex disponibles', noSelectedTask: 'No hay ninguna tarea seleccionada', emptyTask: 'Esta tarea aun no tiene contenido', backToBottom: 'Volver al final', send: 'Enviar', plan: 'Plan',
  search: { title: 'Buscar tareas', placeholder: 'Buscar proyectos y tareas', close: 'Cerrar busqueda', minimum: 'Introduce al menos dos caracteres', empty: 'No hay tareas coincidentes' },
  notifications: { ...en.notifications, title: 'Notificaciones', readAll: 'Marcar todo como leido', empty: 'No hay notificaciones', events: { runtime_connected: 'Codex Runtime conectado', runtime_disconnected: 'Codex Runtime sin conexion', device_paired: 'Nuevo dispositivo vinculado', device_revoked: 'Dispositivo revocado', task_completed: 'Tarea completada', task_failed: 'La tarea ha fallado', deploy_completed: 'Actualizacion completada', runtime_update_completed: 'Actualizacion completada', deploy_failed: 'La actualizacion ha fallado', runtime_update_failed: 'La actualizacion ha fallado', default: 'Estado de CC-Connect actualizado' } },
  scheduled: { ...en.scheduled, title: 'Programadas', subtitle: 'Gestionadas por Codex App en el dispositivo seleccionado', name: 'Nombre', kind: 'Tipo', cron: 'Tarea independiente', heartbeat: 'Seguimiento de tarea', rrule: 'Regla de programacion', targetTask: 'Tarea de destino', selectTask: 'Selecciona una tarea', prompt: 'Instrucciones', empty: 'No hay tareas programadas', active: 'Activa', paused: 'Pausada' },
  plugins: { ...en.plugins, title: 'Complementos', subtitle: 'Catalogo oficial del dispositivo Codex seleccionado', empty: 'No hay complementos', installed: 'Instalado', available: 'Disponible', enabled: 'Activado' },
  archived: { ...en.archived, title: 'Tareas archivadas', subtitle: 'Ver y restaurar tareas archivadas en Codex App', empty: 'No hay tareas archivadas', restore: 'Restaurar', restored: 'Tarea restaurada' },
  settings: { ...en.settings, navigation: 'Navegacion de ajustes', back: 'Volver a la aplicacion', search: 'Buscar ajustes...', noMatch: 'No hay ajustes coincidentes', personal: 'Personal', connections: 'Conexiones', system: 'Sistema', archive: 'Archivo', general: 'General', appearance: 'Apariencia', account: 'Cuenta', devices: 'Dispositivos', updates: 'Actualizaciones', archived: 'Tareas archivadas' },
};

const ko = {
  ...en,
  workspaceNavigation: '작업 공간 탐색', workspaceActions: '작업 공간 작업', closeNavigation: '탐색 닫기', openNavigation: '탐색 열기', newTask: '새 작업', projects: '프로젝트', noProjects: 'Codex 프로젝트가 없습니다',
  noAvailableProjects: '사용 가능한 Codex 프로젝트가 없습니다', noSelectedTask: '선택된 작업이 없습니다', emptyTask: '아직 작업 내용이 없습니다', backToBottom: '맨 아래로', send: '보내기', plan: '계획',
  search: { title: '작업 검색', placeholder: '프로젝트와 작업 검색', close: '검색 닫기', minimum: '두 글자 이상 입력하세요', empty: '일치하는 작업이 없습니다' },
  notifications: { ...en.notifications, title: '알림', readAll: '모두 읽음', empty: '알림이 없습니다', events: { runtime_connected: 'Codex Runtime 연결됨', runtime_disconnected: 'Codex Runtime 오프라인', device_paired: '새 기기 페어링됨', device_revoked: '기기 취소됨', task_completed: '작업 완료됨', task_failed: '작업 실패', deploy_completed: '업데이트 완료됨', runtime_update_completed: '업데이트 완료됨', deploy_failed: '업데이트 실패', runtime_update_failed: '업데이트 실패', default: 'CC-Connect 상태 업데이트됨' } },
  scheduled: { ...en.scheduled, title: '예약됨', subtitle: '선택한 기기의 Codex App에서 관리', name: '이름', kind: '유형', cron: '독립 작업', heartbeat: '작업 후속 조치', rrule: '일정 규칙', targetTask: '대상 작업', selectTask: '작업 선택', prompt: '실행 내용', empty: '예약된 작업이 없습니다', active: '실행 중', paused: '일시 중지' },
  plugins: { ...en.plugins, title: '플러그인', subtitle: '선택한 Codex 기기의 공식 플러그인 카탈로그', empty: '플러그인이 없습니다', installed: '설치됨', available: '설치 가능', enabled: '활성화됨' },
  archived: { ...en.archived, title: '보관된 작업', subtitle: 'Codex App에서 보관된 작업 보기 및 복원', empty: '보관된 작업이 없습니다', restore: '복원', restored: '작업을 복원했습니다' },
  settings: { ...en.settings, navigation: '설정 탐색', back: '앱으로 돌아가기', search: '설정 검색...', noMatch: '일치하는 설정이 없습니다', personal: '개인', connections: '연결', system: '시스템', archive: '보관', general: '일반', appearance: '모양', account: '계정', devices: '기기', updates: '업데이트', archived: '보관된 작업' },
};

const ru = {
  ...en,
  workspaceNavigation: 'Навигация рабочей области', workspaceActions: 'Действия рабочей области', closeNavigation: 'Закрыть навигацию', openNavigation: 'Открыть навигацию', newTask: 'Новая задача', projects: 'Проекты', noProjects: 'Нет проектов Codex',
  noAvailableProjects: 'Нет доступных проектов Codex', noSelectedTask: 'Задача не выбрана', emptyTask: 'В этой задаче пока нет содержимого', backToBottom: 'К последнему сообщению', send: 'Отправить', plan: 'План',
  search: { title: 'Поиск задач', placeholder: 'Поиск проектов и задач', close: 'Закрыть поиск', minimum: 'Введите не менее двух символов', empty: 'Подходящих задач нет' },
  notifications: { ...en.notifications, title: 'Уведомления', readAll: 'Прочитать все', empty: 'Нет уведомлений', events: { runtime_connected: 'Codex Runtime подключен', runtime_disconnected: 'Codex Runtime не в сети', device_paired: 'Новое устройство сопряжено', device_revoked: 'Устройство отозвано', task_completed: 'Задача завершена', task_failed: 'Ошибка задачи', deploy_completed: 'Обновление завершено', runtime_update_completed: 'Обновление завершено', deploy_failed: 'Ошибка обновления', runtime_update_failed: 'Ошибка обновления', default: 'Статус CC-Connect обновлен' } },
  scheduled: { ...en.scheduled, title: 'Запланировано', subtitle: 'Управляется Codex App на выбранном устройстве', name: 'Название', kind: 'Тип', cron: 'Отдельная задача', heartbeat: 'Продолжение задачи', rrule: 'Правило расписания', targetTask: 'Целевая задача', selectTask: 'Выберите задачу', prompt: 'Инструкции', empty: 'Нет запланированных задач', active: 'Активно', paused: 'Приостановлено' },
  plugins: { ...en.plugins, title: 'Плагины', subtitle: 'Официальный каталог выбранного устройства Codex', empty: 'В каталоге нет плагинов', installed: 'Установлен', available: 'Доступен', enabled: 'Включен' },
  archived: { ...en.archived, title: 'Архивные задачи', subtitle: 'Просмотр и восстановление задач из архива Codex App', empty: 'Архивных задач нет', restore: 'Восстановить', restored: 'Задача восстановлена' },
  settings: { ...en.settings, navigation: 'Навигация настроек', back: 'Вернуться в приложение', search: 'Поиск настроек...', noMatch: 'Подходящих настроек нет', personal: 'Личное', connections: 'Подключения', system: 'Система', archive: 'Архив', general: 'Общие', appearance: 'Оформление', account: 'Аккаунт', devices: 'Устройства', updates: 'Обновления', archived: 'Архивные задачи' },
};

export default { en, zh, 'zh-TW': zhTW, ja, es, ko, ru };
