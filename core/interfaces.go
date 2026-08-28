package core

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

// Platform abstracts a messaging platform (Feishu, DingTalk, Slack, etc.).
type Platform interface {
	Name() string
	Start(handler MessageHandler) error
	Reply(ctx context.Context, replyCtx any, content string) error
	Send(ctx context.Context, replyCtx any, content string) error
	Stop() error
}

// ErrNotSupported indicates a platform doesn't support a particular operation.
var ErrNotSupported = errors.New("operation not supported by this platform")

// ReplyContextReconstructor is an optional interface for platforms that can
// recreate a reply context from a session key. This is needed for cron jobs
// to send messages to users without an incoming message.
type ReplyContextReconstructor interface {
	ReconstructReplyCtx(sessionKey string) (any, error)
}

// RelayGroupVisibilityTarget is an optional interface for platforms that
// want to customise the session key used when echoing relay request /
// response messages into the group chat for visibility.  Platforms that
// understand the concept of a thread, topic, or sub-conversation can
// return a thread-scoped session key so the visibility echoes land in
// the same conversation that triggered the relay; platforms without
// such a concept simply don't implement this interface and core falls
// back to the legacy "<platform>:<chatID>:relay" target.
//
// Returning (key, true) → core uses key verbatim as the group session
// key for visibility echoes.
// Returning ("", false) → core falls back to the legacy default.
type RelayGroupVisibilityTarget interface {
	RelayGroupVisibilityKey(callerSessionKey string) (groupSessionKey string, ok bool)
}

// MessageRecallDetector is an optional interface for platforms that can check
// whether the message targeted by a reply context was recalled/deleted.
type MessageRecallDetector interface {
	IsMessageRecalled(ctx context.Context, replyCtx any) (bool, error)
}

// CronReplyTargetResolver is an optional interface for platforms that need to
// map a logical cron session key to the actual reply target used at execution
// time. This is useful for platforms where proactive replies may need to create
// or switch to a thread before the cron run starts.
//
// Implementations that do not need special handling should return
// ErrNotSupported so callers can fall back to ReconstructReplyCtx(sessionKey).
type CronReplyTargetResolver interface {
	ResolveCronReplyTarget(sessionKey string, title string) (resolvedSessionKey string, replyCtx any, err error)
}

// SessionEnvInjector is an optional interface for agents that accept
// per-session environment variables (e.g. CC_PROJECT, CC_SESSION_KEY).
type SessionEnvInjector interface {
	SetSessionEnv(env []string)
}

// FormattingInstructionProvider is an optional interface for platforms that
// provide platform-specific formatting instructions for the agent system prompt
// (e.g., Slack mrkdwn vs standard Markdown).
type FormattingInstructionProvider interface {
	FormattingInstructions() string
}

// PlatformPromptInjector is an optional interface for agents that can receive
// platform-specific prompt fragments (e.g., formatting instructions).
// The engine calls this before StartSession when the platform provides formatting.
type PlatformPromptInjector interface {
	SetPlatformPrompt(prompt string)
}

// AgentSystemPrompt 返回飞书消息通道需要的最小投递约定。
func AgentSystemPrompt() string {
	return `You are responding through CC-Connect's Feishu task channel.
Codex Desktop App remains the sole owner of projects, tasks, turns, and writes.
Your normal text response is delivered automatically; do not invoke cc-connect CLI commands.

If the current turn should produce no user-visible message, respond with NO_REPLY on its own line.
Use NO_REPLY sparingly; when in doubt, send a brief normal response.`
}

// SystemPromptSupporter is an optional marker interface for agents that
// natively inject AgentSystemPrompt() (e.g., via --append-system-prompt).
type SystemPromptSupporter interface {
	HasSystemPromptSupport() bool
}

// SessionIDValidator is an optional interface for agents that can validate
// whether a stored session ID actually belongs to the current project's
// session store. The engine uses this to prevent cross-project session
// context leakage (issue #599): a stale ID from another project's workspace
// would otherwise resume the wrong conversation history.
//
// Implementations should return false when:
//   - the session ID is empty
//   - the session file does not exist under the agent's per-project store
//   - the agent cannot determine the current project directory
//
// The engine treats a false return as "clear the stored ID and start fresh".
type SessionIDValidator interface {
	ValidateSessionID(ctx context.Context, sessionID string) bool
}

// TypingIndicator is an optional interface for platforms that can show a
// "processing" indicator (typing bubble, emoji reaction, etc.) while the
// agent is working. StartTyping is called when processing begins and returns
// a stop function that the caller must invoke when processing ends.
type TypingIndicator interface {
	StartTyping(ctx context.Context, replyCtx any) (stop func())
}

// TypingIndicatorDone is an optional interface for platforms that can show a
// "done" reaction after processing completes. The engine calls AddDoneReaction
// when the agent finishes a multi-round turn in quiet mode, so the user gets
// a push notification (e.g. Feishu card edits don't trigger pushes).
type TypingIndicatorDone interface {
	AddDoneReaction(replyCtx any)
}

// AtMentionSender is an optional interface for platforms that support @mention in
// reply messages (e.g. DingTalk). Platforms that implement this interface can
// include @user notifications when replying in group chats.
type AtMentionSender interface {
	ReplyWithAt(ctx context.Context, replyCtx any, content string, atUsers []string, atAll bool) error
}

// ImageSender is an optional interface for platforms that support sending images.
type ImageSender interface {
	SendImage(ctx context.Context, replyCtx any, img ImageAttachment) error
}

// FileSender is an optional interface for platforms that support sending files.
type FileSender interface {
	SendFile(ctx context.Context, replyCtx any, file FileAttachment) error
}

// MessageUpdater is an optional interface for platforms that support updating messages.
type MessageUpdater interface {
	UpdateMessage(ctx context.Context, replyCtx any, content string) error
}

// StatusFooterSender is an optional Platform extension for sending a reply
// with a structured per-turn status footer rendered using platform-specific
// dim/small styling (e.g. Lark `text_size: "notation"`). Platforms that do
// not implement it fall back to receiving the footer appended inline to the
// content via Send/SendWithButtons/...
type StatusFooterSender interface {
	SendWithStatusFooter(ctx context.Context, replyCtx any, content, footer string) error
}

// StatusFooterUpdater is the streaming-preview counterpart of
// StatusFooterSender: it patches an existing preview message with a final
// content + structured status footer block.
type StatusFooterUpdater interface {
	UpdateMessageWithStatusFooter(ctx context.Context, replyCtx any, content, footer string) error
}

// ProgressStyleProvider is an optional interface for platforms that expose
// a preferred style for intermediate progress rendering.
// Typical values: "legacy", "compact", "card".
type ProgressStyleProvider interface {
	ProgressStyle() string
}

// ProgressCardPayloadSupport is an optional interface for platforms that can
// parse and render structured progress-card payloads.
type ProgressCardPayloadSupport interface {
	SupportsProgressCardPayload() bool
}

// ProgressUpdateThrottler is an optional interface for platforms that need
// rate-limited progress edits (e.g. Discord's ~5 edits / 5s per channel).
type ProgressUpdateThrottler interface {
	ProgressUpdateInterval() time.Duration
}

// ButtonOption represents a clickable inline button.
type ButtonOption struct {
	Text string // display text on the button
	Data string // callback data returned when clicked (≤64 bytes for Telegram)
}

// InlineButtonSender is an optional interface for platforms that support
// sending messages with clickable inline buttons (e.g. Telegram Inline Keyboard).
// Buttons is a 2D slice: each inner slice is one row of buttons.
type InlineButtonSender interface {
	SendWithButtons(ctx context.Context, replyCtx any, content string, buttons [][]ButtonOption) error
}

// CardSender is an optional interface for platforms that support sending
// structured rich cards (e.g. Feishu Interactive Card). Platforms that do not
// implement this interface will receive a plain-text fallback via Card.RenderText().
type CardSender interface {
	SendCard(ctx context.Context, replyCtx any, card *Card) error
	ReplyCard(ctx context.Context, replyCtx any, card *Card) error
}

// CardNavigationHandler is called by platforms to render a card for in-place
// card updates (e.g. Feishu card.action.trigger callback). The action string
// uses prefixes like "nav:/model" or "act:/model 3".
type CardNavigationHandler func(action string, sessionKey string) *Card

// CardNavigable is an optional interface for platforms that support in-place
// card navigation (updating the existing card instead of sending a new message).
type CardNavigable interface {
	SetCardNavigationHandler(h CardNavigationHandler)
}

// CardRefresher is an optional interface for platforms that can update a
// previously rendered card in-place after the original callback has returned.
// This is used when async operations (e.g. delete-mode deletion) need to
// refresh a "loading" card with the final result. Platforms that implement
// this interface should track the message ID from card action callbacks and
// use it to patch the card content.
type CardRefresher interface {
	RefreshCard(ctx context.Context, sessionKey string, card *Card) error
}

// PlatformLifecycleHandler receives readiness state transitions from async
// recoverable platforms.
type PlatformLifecycleHandler interface {
	OnPlatformReady(p Platform)
	OnPlatformUnavailable(p Platform, err error)
}

// AsyncRecoverablePlatform is an optional interface for platforms that start
// a background recovery loop and later report readiness or unavailability.
//
// Platforms implementing this interface may return from Start() before they are
// actually ready to receive traffic. Callers must treat OnPlatformReady as the
// signal that deferred platform capabilities may be initialized and the
// platform is usable. A nil Start() return therefore means the recovery loop
// was launched successfully, not necessarily that an initial connection was
// established.
type AsyncRecoverablePlatform interface {
	Platform
	SetLifecycleHandler(h PlatformLifecycleHandler)
}

// MessageHandler is called by platforms when a new message arrives.
type MessageHandler func(p Platform, msg *Message)

// Agent abstracts an AI coding assistant (Claude Code, Cursor, Gemini CLI, etc.).
// All agents must support persistent bidirectional sessions via StartSession.
type Agent interface {
	Name() string
	// StartSession creates or resumes an interactive session with a persistent process.
	StartSession(ctx context.Context, sessionID string) (AgentSession, error)
	// ListSessions returns sessions known to the agent backend.
	ListSessions(ctx context.Context) ([]AgentSessionInfo, error)
	Stop() error
}

// AgentSession represents a running interactive agent session with a persistent process.
type AgentSession interface {
	// Send sends a user message (with optional images and files) to the running
	// agent process. messageID is the platform message ID; agents thread it
	// into SaveFilesToDisk so attachments from different messages land in
	// distinct per-message subdirectories (issue #1552). It may be empty for
	// synthesized messages, in which case SaveFilesToDisk falls back to a
	// best-effort atomic-write path that refuses to overwrite.
	Send(prompt string, messageID string, images []ImageAttachment, files []FileAttachment) error
	// RespondPermission sends a permission decision back to the agent process.
	RespondPermission(requestID string, result PermissionResult) error
	// Events returns the channel that emits agent events (kept open across turns).
	Events() <-chan Event
	// CurrentSessionID returns the current agent-side session ID.
	CurrentSessionID() string
	// Alive returns true if the underlying process is still running.
	Alive() bool
	// Close terminates the session and its underlying process.
	Close() error
}

// AgentSessionCreationTarget receives the authoritative project and optional
// title for a session whose first Send creates the real agent task.
type AgentSessionCreationTarget interface {
	SetCreationTarget(projectID, title string)
}

// AgentSessionHostTarget receives the host identifier published by the
// current Agent's session catalog before a session sends or observes a task.
type AgentSessionHostTarget interface {
	SetHostID(hostID string)
}

// PermissionResult represents the user's decision on a permission request.
type PermissionResult struct {
	Behavior     string         `json:"behavior"`               // "allow" or "deny"
	UpdatedInput map[string]any `json:"updatedInput,omitempty"` // echoed back for allow
	Message      string         `json:"message,omitempty"`      // reason for deny
}

// ToolAuthorizer is an optional interface for agents that support dynamic tool authorization.
type ToolAuthorizer interface {
	AddAllowedTools(tools ...string) error
	GetAllowedTools() []string
}

// HistoryProvider is an optional interface for agents that can retrieve
// conversation history from their backend session files.
type HistoryProvider interface {
	GetSessionHistory(ctx context.Context, sessionID string, limit int) ([]HistoryEntry, error)
}

// AgentProjectInfo describes a project owned by an external agent application.
// Path is metadata only; cc-connect must not infer ownership from it.
type AgentProjectInfo struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	Path            string `json:"path,omitempty"`
	HostID          string `json:"host_id,omitempty"`
	Kind            string `json:"kind,omitempty"`
	IsGitRepository bool   `json:"is_git_repository"`
}

// AgentSessionSnapshot is the authoritative history snapshot returned by an
// agent application. Cursor is opaque and is only passed back to that agent.
type AgentSessionSnapshot struct {
	Session    AgentSessionInfo `json:"session"`
	History    []HistoryEntry   `json:"history"`
	Cursor     string           `json:"cursor,omitempty"`
	WaitCursor string           `json:"wait_cursor,omitempty"`
	HasMore    bool             `json:"has_more"`
}

// AgentSessionListRequest describes one page of authoritative agent tasks.
// ProjectID is owned by the external agent application; Cursor is opaque to
// callers and must only be returned to the same agent implementation.
type AgentSessionListRequest struct {
	ProjectID string `json:"project_id,omitempty"`
	Cursor    string `json:"cursor,omitempty"`
	Limit     int    `json:"limit,omitempty"`
}

// AgentSessionPage is a stable page of authoritative agent tasks.
type AgentSessionPage struct {
	Sessions  []AgentSessionInfo `json:"sessions"`
	Cursor    string             `json:"cursor,omitempty"`
	HasMore   bool               `json:"has_more"`
	TotalHint int                `json:"total_hint,omitempty"`
}

// AgentTaskContentPart is a safe, renderable part of a Codex task item.
type AgentTaskContentPart struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

// AgentTaskItem preserves the authoritative item type and identifier returned
// by the owner application. Unsupported source items remain explicit instead
// of being dropped or converted into assistant text.
type AgentTaskItem struct {
	Type       string                 `json:"type"`
	ID         string                 `json:"id"`
	Content    []AgentTaskContentPart `json:"content,omitempty"`
	Text       string                 `json:"text,omitempty"`
	Status     string                 `json:"status,omitempty"`
	SourceType string                 `json:"source_type,omitempty"`
	RawContent json.RawMessage        `json:"raw_content,omitempty"`
}

// AgentTaskTurn is the virtualization and pagination unit used by the Codex UI.
type AgentTaskTurn struct {
	ID          string          `json:"id"`
	Status      string          `json:"status,omitempty"`
	StartedAt   time.Time       `json:"started_at,omitempty"`
	CompletedAt time.Time       `json:"completed_at,omitempty"`
	Items       []AgentTaskItem `json:"items"`
}

// AgentTaskPage describes the current read page. Order is normalized to
// oldest_first before crossing the public API boundary.
type AgentTaskPage struct {
	Cursor  string `json:"cursor,omitempty"`
	HasMore bool   `json:"has_more"`
	Order   string `json:"order"`
}

// AgentTaskSnapshot is the authoritative typed task view used by the Codex
// first-party API. It does not take task writer ownership.
type AgentTaskSnapshot struct {
	Task       AgentSessionInfo `json:"task"`
	Turns      []AgentTaskTurn  `json:"turns"`
	Page       AgentTaskPage    `json:"page"`
	WaitCursor string           `json:"wait_cursor,omitempty"`
}

type AgentSessionCreateRequest struct {
	ProjectID string `json:"project_id,omitempty"`
	Prompt    string `json:"prompt"`
	Title     string `json:"title,omitempty"`
	UseLocal  bool   `json:"use_local"`
}

type AgentSessionMetadataPatch struct {
	Title    *string `json:"title,omitempty"`
	Pinned   *bool   `json:"pinned,omitempty"`
	Archived *bool   `json:"archived,omitempty"`
}

// AgentSessionCapability describes whether an audited semantic operation is
// currently available from the authoritative agent application.
type AgentSessionCapability struct {
	Supported bool   `json:"supported"`
	Reason    string `json:"reason,omitempty"`
}

// AgentSessionCapabilities is the stable cc-connect capability vocabulary.
// Implementations derive these values from their current backend schema and
// must not expose unknown backend tools directly.
type AgentSessionCapabilities struct {
	Create              AgentSessionCapability `json:"create"`
	Rename              AgentSessionCapability `json:"rename"`
	Pin                 AgentSessionCapability `json:"pin"`
	Archive             AgentSessionCapability `json:"archive"`
	Fork                AgentSessionCapability `json:"fork"`
	Handoff             AgentSessionCapability `json:"handoff"`
	InteractiveResponse AgentSessionCapability `json:"interactive_response"`
	AutomationMutation  AgentSessionCapability `json:"automation_mutation"`
}

// AgentTaskSearchRequest describes a bounded search owned by the external app.
type AgentTaskSearchRequest struct {
	Query string `json:"query"`
	Limit int    `json:"limit,omitempty"`
}

// AgentTaskSearchResult keeps the task and its authoritative project identity.
type AgentTaskSearchResult struct {
	DeviceID string           `json:"device_id,omitempty"`
	Task     AgentSessionInfo `json:"task"`
}

// AgentAutomation is a safe projection of one Codex-owned automation.
type AgentAutomation struct {
	ID                   string `json:"id"`
	Name                 string `json:"name"`
	Kind                 string `json:"kind"`
	Prompt               string `json:"prompt"`
	RRule                string `json:"rrule"`
	Status               string `json:"status"`
	Destination          string `json:"destination,omitempty"`
	ExecutionEnvironment string `json:"execution_environment,omitempty"`
	ProjectID            string `json:"project_id,omitempty"`
	TargetThreadID       string `json:"target_thread_id,omitempty"`
	Model                string `json:"model,omitempty"`
	ReasoningEffort      string `json:"reasoning_effort,omitempty"`
	NotificationPolicy   string `json:"notification_policy,omitempty"`
}

// AgentAutomationMutation is passed only to the owner app's mutation tool.
type AgentAutomationMutation struct {
	ID                   string `json:"id,omitempty"`
	Name                 string `json:"name,omitempty"`
	Kind                 string `json:"kind,omitempty"`
	Prompt               string `json:"prompt,omitempty"`
	RRule                string `json:"rrule,omitempty"`
	Status               string `json:"status,omitempty"`
	Destination          string `json:"destination,omitempty"`
	ExecutionEnvironment string `json:"execution_environment,omitempty"`
	ProjectID            string `json:"project_id,omitempty"`
	TargetThreadID       string `json:"target_thread_id,omitempty"`
	Model                string `json:"model,omitempty"`
	ReasoningEffort      string `json:"reasoning_effort,omitempty"`
	NotificationPolicy   string `json:"notification_policy,omitempty"`
}

// AgentPlugin is the structured result returned by the official plugin manager.
type AgentPlugin struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Marketplace   string `json:"marketplace"`
	Version       string `json:"version,omitempty"`
	Installed     bool   `json:"installed"`
	Enabled       bool   `json:"enabled"`
	InstallPolicy string `json:"install_policy,omitempty"`
	AuthPolicy    string `json:"auth_policy,omitempty"`
}

// AgentProjectCatalog exposes projects from the authoritative agent app.
type AgentProjectCatalog interface {
	ListProjects(ctx context.Context) ([]AgentProjectInfo, error)
}

// AgentSessionPageLister lists authoritative tasks with project filtering and
// opaque pagination owned by the agent implementation.
type AgentSessionPageLister interface {
	ListSessionPage(ctx context.Context, request AgentSessionListRequest) (AgentSessionPage, error)
}

// AgentTaskReader exposes typed turns without flattening owner-app items.
type AgentTaskReader interface {
	ReadTask(ctx context.Context, sessionID, hostID, cursor string, limit int) (AgentTaskSnapshot, error)
}

// AgentTaskWaiter waits for an owner-app change and returns a converged typed
// snapshot. The wait cursor is opaque to cc-connect.
type AgentTaskWaiter interface {
	WaitTask(ctx context.Context, sessionID, hostID, cursor string, timeout time.Duration) (AgentTaskSnapshot, error)
}

// AgentSessionReader reads history without taking over the task writer.
type AgentSessionReader interface {
	ReadSession(ctx context.Context, sessionID, hostID, cursor string, limit int) (AgentSessionSnapshot, error)
}

// AgentSessionWaiter waits for an authoritative task state change and then
// returns the converged snapshot. The cursor is opaque to cc-connect.
type AgentSessionWaiter interface {
	WaitSession(ctx context.Context, sessionID, hostID, cursor string, timeout time.Duration) (AgentSessionSnapshot, error)
}

// AgentSessionCreator creates a task through the authoritative agent app.
type AgentSessionCreator interface {
	CreateSession(ctx context.Context, request AgentSessionCreateRequest) (AgentSessionInfo, error)
}

// AgentSessionMetadataController changes task metadata through the owner app.
type AgentSessionMetadataController interface {
	UpdateSessionMetadata(ctx context.Context, sessionID, hostID string, patch AgentSessionMetadataPatch) error
}

// AgentSessionCapabilityCatalog reports the current audited capabilities for
// one authoritative app host. hostID may be empty for a local single-host app.
type AgentSessionCapabilityCatalog interface {
	SessionCapabilities(ctx context.Context, hostID string) (AgentSessionCapabilities, error)
}

type AgentTaskSearcher interface {
	SearchTasks(ctx context.Context, request AgentTaskSearchRequest) ([]AgentTaskSearchResult, error)
}

type AgentArchivedTaskLister interface {
	ListArchivedTasks(ctx context.Context, limit int) (AgentSessionPage, error)
}

type AgentAutomationController interface {
	ListAutomations(ctx context.Context) ([]AgentAutomation, error)
	CreateAutomation(ctx context.Context, mutation AgentAutomationMutation) (AgentAutomation, error)
	UpdateAutomation(ctx context.Context, mutation AgentAutomationMutation) (AgentAutomation, error)
	DeleteAutomation(ctx context.Context, id string) error
}

type AgentPluginController interface {
	ListPlugins(ctx context.Context, available bool) ([]AgentPlugin, error)
	InstallPlugin(ctx context.Context, id string) (AgentPlugin, error)
	RemovePlugin(ctx context.Context, id string) error
}

// AuthoritativeSessionHistory marks agents whose backend owns all history.
// SessionManager must only persist platform-to-session selection for them.
type AuthoritativeSessionHistory interface {
	AuthoritativeSessionHistory()
}

// ProviderConfig holds API provider settings for an agent.
type ProviderConfig struct {
	Name     string
	APIKey   string
	BaseURL  string
	Model    string
	Models   []ModelOption     // pre-configured list of available models for this provider
	Thinking string            // override thinking type sent to this provider ("disabled", "enabled", or "" for no rewrite)
	Env      map[string]string // arbitrary extra env vars (e.g. CLAUDE_CODE_USE_BEDROCK=1)
	// Codex-specific provider config (maps to Codex model_providers.<name>)
	CodexWireAPI     string            // wire API format (e.g. "responses")
	CodexHTTPHeaders map[string]string // custom HTTP headers
}

// ProviderSwitcher is an optional interface for agents that support multiple API providers.
type ProviderSwitcher interface {
	SetProviders(providers []ProviderConfig)
	SetActiveProvider(name string) bool
	GetActiveProvider() *ProviderConfig
	ListProviders() []ProviderConfig
}

// MemoryFileProvider is an optional interface for agents that support
// persistent instruction files (CLAUDE.md, AGENTS.md, GEMINI.md, etc.).
// The engine uses these paths for the /memory command.
type MemoryFileProvider interface {
	ProjectMemoryFile() string // project-level instruction file (e.g., <work_dir>/CLAUDE.md)
	GlobalMemoryFile() string  // user-level instruction file (e.g., ~/.claude/CLAUDE.md)
}

// ModelSwitcher is an optional interface for agents that support runtime model switching.
// Model changes take effect on the next session (existing sessions keep their model).
type ModelSwitcher interface {
	SetModel(model string)
	GetModel() string
	// AvailableModels tries to fetch models from the provider API.
	// Falls back to a built-in list on failure.
	AvailableModels(ctx context.Context) []ModelOption
}

// ReasoningEffortSwitcher is an optional interface for agents that support
// runtime switching of reasoning effort.
type ReasoningEffortSwitcher interface {
	SetReasoningEffort(effort string)
	GetReasoningEffort() string
	AvailableReasoningEfforts() []string
}

// ModelOption describes a selectable model.
type ModelOption struct {
	Name  string // model identifier passed to CLI
	Desc  string // short description (display_name or empty)
	Alias string // optional short alias for the /model command (e.g. "codex" for "gpt-5.3-codex")
}

// UsageReporter is an optional interface for agents that can report account or
// model quota usage from their backing provider.
type UsageReporter interface {
	GetUsage(ctx context.Context) (*UsageReport, error)
}

// UsageReport is a provider-neutral quota snapshot returned by UsageReporter.
type UsageReport struct {
	Provider  string
	AccountID string
	UserID    string
	Email     string
	Plan      string
	Buckets   []UsageBucket
	Credits   *UsageCredits
}

// UsageBucket groups one logical quota, such as standard requests or code review.
type UsageBucket struct {
	Name         string
	Allowed      bool
	LimitReached bool
	Windows      []UsageWindow
}

// UsageWindow describes a single quota window.
type UsageWindow struct {
	Name              string
	UsedPercent       int
	WindowSeconds     int
	ResetAfterSeconds int
	ResetAtUnix       int64
}

// UsageCredits contains optional credit/balance metadata.
type UsageCredits struct {
	HasCredits bool
	Unlimited  bool
	Balance    string
}

// ContextUsageReporter is an optional interface for running agent sessions that
// can report real runtime context usage for the active conversation.
type ContextUsageReporter interface {
	GetContextUsage() *ContextUsage
}

// ContextUsage describes runtime context consumption for the active session.
type ContextUsage struct {
	// UsedTokens is the current token load to compare against ContextWindow when
	// computing remaining context capacity for the next turn.
	UsedTokens int
	// BaselineTokens is the portion of the context window always occupied by
	// fixed runtime/system instructions and therefore excluded from user-visible
	// "left" calculations when the agent provides it.
	BaselineTokens           int
	TotalTokens              int
	InputTokens              int
	CachedInputTokens        int // cache-read tokens (prior context retrieved from cache)
	CacheCreationInputTokens int // cache-write tokens (new content written to cache)
	OutputTokens             int
	ReasoningOutputTokens    int
	ContextWindow            int
}

// ContextCompressor is an optional interface for agents that support
// compressing/compacting the conversation context within a running session.
// CompressCommand returns the native slash command (e.g. "/compact", "/compress")
// that will be forwarded to the agent process. Return "" if not supported.
type ContextCompressor interface {
	CompressCommand() string
}

// AgentSessionCanceller is an optional interface for agent sessions that support
// cancelling the current turn without terminating the session or its underlying
// process. When implemented, the engine calls CancelTurn instead of Close() for
// /stop, allowing the session to remain alive for the next user message.
type AgentSessionCanceller interface {
	CancelTurn() error
}

// CommandProvider is an optional interface for agents that expose custom slash
// commands via local files (e.g. .claude/commands/*.md). The engine scans the
// returned directories for *.md files and registers them as slash commands.
type CommandProvider interface {
	CommandDirs() []string
}

// SkillProvider is an optional interface for agents that expose skills via
// local directories (e.g. .claude/skills/<name>/SKILL.md). Only the depth-1
// layout is recognised: each immediate subdirectory of the returned dirs
// that contains a SKILL.md is registered as a skill. Nested SKILL.md files
// (e.g. inside `<name>/references/...`) are treated as skill assets and
// ignored — they match the Claude Code CLI convention (issue #1304) and
// prevent phantom slash commands from leaking into platform command menus.
// Skills are project-level and agent-specific — they are NOT shared across
// different agent types.
type SkillProvider interface {
	SkillDirs() []string
}

// SessionDeleter is an optional interface for agents that support deleting sessions.
type SessionDeleter interface {
	DeleteSession(ctx context.Context, sessionID string) error
}

type SessionTitleProvider interface {
	GetSessionTitle(sessionID string) string
}

// WorkDirSwitcher is an optional interface for agents that support runtime
// work directory switching. The change takes effect on the next session start;
// the current running session is terminated automatically by the engine.
type WorkDirSwitcher interface {
	SetWorkDir(dir string)
	GetWorkDir() string
}

// AgentOptsProvider is an optional interface for agents that need to carry
// their full configuration options when the engine clones a per-workspace
// agent instance in multi-workspace mode. The engine merges the returned map
// into the workspace opts before calling the agent factory, giving workspace
// agents access to agent-specific options (e.g. "session" for the tmux agent)
// that are not covered by the standard GetModel / GetMode accessors.
// work_dir is always overridden by the engine and must not be returned here.
type AgentOptsProvider interface {
	BaseOpts() map[string]any
}

// ModeSwitcher is an optional interface for agents that support runtime permission mode switching.
type ModeSwitcher interface {
	SetMode(mode string)
	GetMode() string
	PermissionModes() []PermissionModeInfo
}

// WorkspaceAgentOptionSnapshotter is an optional interface for agents that can
// export reusable constructor options needed to recreate an equivalent agent in
// a different workspace. Snapshot values should omit work_dir; the caller is
// responsible for setting the target workspace explicitly. Provider wiring and
// run_as propagation may still be handled separately by the engine.
type WorkspaceAgentOptionSnapshotter interface {
	WorkspaceAgentOptions() map[string]any
}

// LiveModeSwitcher is an optional interface for running agent sessions that can
// apply a mode change immediately without restarting the process.
type LiveModeSwitcher interface {
	SetLiveMode(mode string) bool
}

// StartupWarner is an optional interface for agent sessions that need to surface
// a one-time warning to the IM user at session start (e.g. when a requested
// permission mode was silently downgraded due to OS constraints). The engine
// sends the returned message to the IM platform immediately after starting the
// session. Returns empty string when no warning is needed.
type StartupWarner interface {
	StartupWarning() string
}

// PermissionModeInfo describes a permission mode for display.
type PermissionModeInfo struct {
	Key    string
	Name   string
	NameZh string
	Desc   string
	DescZh string
}

// BotCommandInfo represents a command for bot menu registration (e.g. Telegram setMyCommands).
type BotCommandInfo struct {
	Command     string // command name without leading "/"
	Description string // short description for the menu
	IsSkill     bool   // whether this entry comes from a skill
}

// CommandRegistrar is an optional interface for platforms that support
// registering commands to the platform's native menu (e.g. Telegram's setMyCommands).
type CommandRegistrar interface {
	RegisterCommands(commands []BotCommandInfo) error
}

// ChannelNameResolver is an optional interface for platforms that can resolve
// channel IDs to human-readable names.
type ChannelNameResolver interface {
	ResolveChannelName(channelID string) (string, error)
}

// StreamingCard represents an active streaming card that aggregates
// an entire agent turn (tool calls, thinking, text) into a single
// updatable message.
type StreamingCard interface {
	// Update replaces the card content with the given markdown.
	// Implementations should throttle calls internally.
	Update(ctx context.Context, content string) error
	// Finalize sends the final content and marks the card as complete.
	Finalize(ctx context.Context, content string) error
	// Failed returns true if the card has entered a failed state.
	Failed() bool
}

// StreamingCardPlatform is an optional interface for platforms that support
// aggregating an entire agent turn into a single updatable card message
// (e.g. DingTalk AI Card). When the engine detects this interface, it
// creates a streaming card at the start of each turn and routes all
// events through it instead of sending individual messages.
type StreamingCardPlatform interface {
	CreateStreamingCard(ctx context.Context, replyCtx any) (StreamingCard, error)
}

// CardStatus represents the visual status of a card header.
type CardStatus string

const (
	CardStatusThinking CardStatus = "thinking" // grey
	CardStatusWorking  CardStatus = "working"  // blue
	CardStatusDone     CardStatus = "done"     // green
	CardStatusError    CardStatus = "error"    // red
)

// PreviewStatusUpdater is an optional interface for platforms that support
// updating the visual status of a preview card header.
type PreviewStatusUpdater interface {
	SetPreviewStatus(previewHandle any, status CardStatus)
}
