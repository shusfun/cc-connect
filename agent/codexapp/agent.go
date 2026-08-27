package codexapp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/chenhg5/cc-connect/core"
)

func init() {
	core.RegisterAgent("codexapp", New)
}

type toolCaller interface {
	Call(ctx context.Context, tool string, arguments any) (json.RawMessage, error)
	HasTool(name string) bool
	Close() error
}

type Agent struct {
	bridge    toolCaller
	projectID string
	workDir   string
	useLocal  bool
	stopOnce  sync.Once
}

func New(options map[string]any) (core.Agent, error) {
	bridgeOptions := BridgeOptions{}
	if value, ok := options["socket_path"].(string); ok {
		bridgeOptions.SocketPath = value
	}
	if value, ok := options["context_thread_id"].(string); ok {
		bridgeOptions.ContextThreadID = value
	}
	if value, ok := options["ipc_socket_path"].(string); ok {
		bridgeOptions.IPCSocketPath = value
	}
	if value, ok := options["bridge_fd"].(int); ok {
		bridgeOptions.InheritedFD = value
	}
	bridge, err := NewBridge(bridgeOptions)
	if err != nil {
		return nil, err
	}
	a := &Agent{bridge: bridge}
	if value, ok := options["project_id"].(string); ok {
		a.projectID = strings.TrimSpace(value)
	}
	if value, ok := options["work_dir"].(string); ok {
		a.workDir = strings.TrimSpace(value)
	}
	if value, ok := options["use_local"].(bool); ok {
		a.useLocal = value
	}
	return a, nil
}

func newAgentWithCaller(caller toolCaller) *Agent { return &Agent{bridge: caller} }

func (a *Agent) Name() string                 { return "codexapp" }
func (a *Agent) AuthoritativeSessionHistory() {}
func (a *Agent) GetWorkDir() string           { return a.workDir }

func (a *Agent) Stop() error {
	var err error
	a.stopOnce.Do(func() { err = a.bridge.Close() })
	return err
}

func (a *Agent) ListProjects(ctx context.Context) ([]core.AgentProjectInfo, error) {
	raw, err := a.callJSON(ctx, "list_projects", map[string]any{})
	if err != nil {
		return nil, err
	}
	var response struct {
		Projects []struct {
			ProjectID       string `json:"projectId"`
			ProjectKind     string `json:"projectKind"`
			Label           string `json:"label"`
			Path            string `json:"path"`
			HostID          string `json:"hostId"`
			IsGitRepository bool   `json:"isGitRepository"`
		} `json:"projects"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return nil, fmt.Errorf("codex app: decode project catalog: %w", err)
	}
	projects := make([]core.AgentProjectInfo, 0, len(response.Projects))
	for _, item := range response.Projects {
		if strings.TrimSpace(item.ProjectID) == "" || strings.TrimSpace(item.Label) == "" {
			return nil, errors.New("codex app: project catalog contains an invalid project")
		}
		projects = append(projects, core.AgentProjectInfo{ID: item.ProjectID, Name: item.Label, Path: item.Path, HostID: item.HostID, Kind: item.ProjectKind, IsGitRepository: item.IsGitRepository})
	}
	return projects, nil
}

func (a *Agent) ListSessions(ctx context.Context) ([]core.AgentSessionInfo, error) {
	projects, err := a.ListProjects(ctx)
	if err != nil {
		return nil, err
	}
	raw, err := a.callJSON(ctx, "list_threads", map[string]any{"limit": 50})
	if err != nil {
		return nil, err
	}
	var response struct {
		Pinned  []threadSummary `json:"pinnedThreads"`
		Threads []threadSummary `json:"threads"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return nil, fmt.Errorf("codex app: decode task list: %w", err)
	}
	result := make([]core.AgentSessionInfo, 0, len(response.Pinned)+len(response.Threads))
	for _, item := range response.Pinned {
		result = append(result, item.info(true, projects))
	}
	for _, item := range response.Threads {
		result = append(result, item.info(false, projects))
	}
	return result, nil
}

type threadSummary struct {
	ID          string `json:"id"`
	ProjectID   string `json:"projectId"`
	ProjectName string `json:"projectName"`
	HostID      string `json:"hostId"`
	Status      string `json:"status"`
	CWD         string `json:"cwd"`
	UpdatedAt   int64  `json:"updatedAt"`
	Title       string `json:"title"`
	Summary     string `json:"summary"`
	PinnedIndex int    `json:"pinnedIndex"`
	Archived    bool   `json:"archived"`
}

func (t threadSummary) info(pinned bool, projects []core.AgentProjectInfo) core.AgentSessionInfo {
	projectID, projectName := t.ProjectID, t.ProjectName
	if projectID == "" {
		cleanCWD := strings.TrimSuffix(filepath.Clean(t.CWD), string(filepath.Separator))
		for _, project := range projects {
			cleanProject := strings.TrimSuffix(filepath.Clean(project.Path), string(filepath.Separator))
			if cleanCWD == cleanProject || strings.HasPrefix(cleanCWD, cleanProject+string(filepath.Separator)) {
				projectID, projectName = project.ID, project.Name
				break
			}
		}
	}
	return core.AgentSessionInfo{ID: t.ID, Summary: firstNonEmpty(t.Title, t.Summary), ModifiedAt: unixTime(t.UpdatedAt), ProjectID: projectID, ProjectName: projectName, CWD: t.CWD, HostID: t.HostID, Status: t.Status, Pinned: pinned, PinnedIndex: t.PinnedIndex, Archived: t.Archived}
}

func (a *Agent) ReadSession(ctx context.Context, sessionID, hostID, cursor string, limit int) (core.AgentSessionSnapshot, error) {
	arguments := map[string]any{"threadId": sessionID, "includeOutputs": false, "maxOutputCharsPerItem": 20000}
	if hostID != "" {
		arguments["hostId"] = hostID
	}
	if cursor != "" {
		arguments["cursor"] = cursor
	}
	if limit > 0 {
		if limit > 10 {
			limit = 10
		}
		arguments["turnLimit"] = limit
	}
	raw, err := a.callJSON(ctx, "read_thread", arguments)
	if err != nil {
		return core.AgentSessionSnapshot{}, err
	}
	return decodeSnapshot(raw)
}

func (a *Agent) GetSessionHistory(ctx context.Context, sessionID string, limit int) ([]core.HistoryEntry, error) {
	snapshot, err := a.ReadSession(ctx, sessionID, "", "", limit)
	return snapshot.History, err
}

func (a *Agent) WaitSession(ctx context.Context, sessionID, hostID, cursor string, timeout time.Duration) (core.AgentSessionSnapshot, error) {
	timeoutMS := timeout.Milliseconds()
	if timeoutMS < 0 {
		timeoutMS = 0
	}
	if timeoutMS > 120000 {
		timeoutMS = 120000
	}
	target := map[string]any{"threadId": sessionID}
	if hostID != "" {
		target["hostId"] = hostID
	}
	if cursor != "" {
		target["afterCursor"] = cursor
	}
	raw, err := a.callJSON(ctx, "wait_threads", map[string]any{"targets": []map[string]any{target}, "timeoutMs": timeoutMS})
	if err != nil {
		return core.AgentSessionSnapshot{}, err
	}
	var waitResult struct {
		Polls []struct {
			Cursor string `json:"cursor"`
			Thread struct {
				ID     string `json:"id"`
				HostID string `json:"hostId"`
				Status struct {
					Type string `json:"type"`
				} `json:"status"`
			} `json:"thread"`
		} `json:"polls"`
	}
	if err := json.Unmarshal(raw, &waitResult); err != nil {
		return core.AgentSessionSnapshot{}, fmt.Errorf("codex app: decode task wait result: %w", err)
	}
	snapshot, err := a.ReadSession(ctx, sessionID, hostID, "", 10)
	if err != nil {
		return core.AgentSessionSnapshot{}, err
	}
	for _, poll := range waitResult.Polls {
		if poll.Thread.ID != sessionID {
			continue
		}
		snapshot.WaitCursor = poll.Cursor
		if poll.Thread.HostID != "" {
			snapshot.Session.HostID = poll.Thread.HostID
		}
		if poll.Thread.Status.Type != "" {
			snapshot.Session.Status = poll.Thread.Status.Type
		}
		break
	}
	return snapshot, nil
}

func (a *Agent) CreateSession(ctx context.Context, request core.AgentSessionCreateRequest) (core.AgentSessionInfo, error) {
	projectID := strings.TrimSpace(request.ProjectID)
	if projectID == "" {
		projectID = a.projectID
	}
	if projectID == "" && a.workDir != "" {
		projects, err := a.ListProjects(ctx)
		if err != nil {
			return core.AgentSessionInfo{}, err
		}
		for _, project := range projects {
			if project.Path == a.workDir {
				projectID = project.ID
				break
			}
		}
	}
	if projectID == "" {
		return core.AgentSessionInfo{}, errors.New("codex app: a Desktop App project is required to create a task")
	}
	useLocal := request.UseLocal || a.useLocal
	environment := "worktree"
	if useLocal {
		environment = "local"
	}
	arguments := map[string]any{"prompt": request.Prompt, "target": map[string]any{"type": "project", "projectId": projectID, "environment": map[string]any{"type": environment}}}
	if strings.TrimSpace(request.Title) != "" {
		arguments["title"] = request.Title
	}
	raw, err := a.callJSON(ctx, "create_thread", arguments)
	if err != nil {
		return core.AgentSessionInfo{}, err
	}
	var response struct {
		ThreadID       string `json:"threadId"`
		ClientThreadID string `json:"clientThreadId"`
		HostID         string `json:"hostId"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return core.AgentSessionInfo{}, fmt.Errorf("codex app: decode created task: %w", err)
	}
	if response.ThreadID == "" {
		if response.ClientThreadID != "" {
			return core.AgentSessionInfo{}, fmt.Errorf("codex app: task setup is still in progress (%s)", response.ClientThreadID)
		}
		return core.AgentSessionInfo{}, errors.New("codex app: create task returned no task id")
	}
	return core.AgentSessionInfo{ID: response.ThreadID, HostID: response.HostID, ProjectID: projectID, Status: "active"}, nil
}

func (a *Agent) UpdateSessionMetadata(ctx context.Context, sessionID, hostID string, patch core.AgentSessionMetadataPatch) error {
	if patch.Title != nil {
		if !a.bridge.HasTool("set_thread_title") {
			return errors.New("codex app: task rename is unavailable in the current App")
		}
		if _, err := a.callJSON(ctx, "set_thread_title", map[string]any{"threadId": sessionID, "title": *patch.Title}); err != nil {
			return err
		}
	}
	if patch.Pinned != nil {
		if !a.bridge.HasTool("set_thread_pinned") {
			return errors.New("codex app: task pinning is unavailable in the current App")
		}
		if _, err := a.callJSON(ctx, "set_thread_pinned", map[string]any{"threadId": sessionID, "pinned": *patch.Pinned}); err != nil {
			return err
		}
	}
	if patch.Archived != nil {
		if !a.bridge.HasTool("set_thread_archived") {
			return errors.New("codex app: task archiving is unavailable in the current App")
		}
		arguments := map[string]any{"threadId": sessionID, "archived": *patch.Archived}
		if hostID != "" {
			arguments["hostId"] = hostID
		}
		if _, err := a.callJSON(ctx, "set_thread_archived", arguments); err != nil {
			return err
		}
	}
	return nil
}

func (a *Agent) SessionCapabilities(context.Context, string) (core.AgentSessionCapabilities, error) {
	capability := func(tool, unavailable string) core.AgentSessionCapability {
		if a.bridge.HasTool(tool) {
			return core.AgentSessionCapability{Supported: true}
		}
		return core.AgentSessionCapability{Reason: unavailable}
	}
	return core.AgentSessionCapabilities{
		Create:              capability("create_thread", "当前 Codex App 不支持创建任务"),
		Rename:              capability("set_thread_title", "当前 Codex App 不支持重命名任务"),
		Pin:                 capability("set_thread_pinned", "当前 Codex App 不支持置顶任务"),
		Archive:             capability("set_thread_archived", "当前 Codex App 不支持归档任务"),
		Fork:                capability("fork_thread", "当前 Codex App 不支持派生任务"),
		Handoff:             capability("handoff_thread", "当前 Codex App 不支持移交任务"),
		InteractiveResponse: core.AgentSessionCapability{Reason: "当前 Desktop Bridge 未审核交互响应工具"},
	}, nil
}

func (a *Agent) StartSession(ctx context.Context, sessionID string) (core.AgentSession, error) {
	sessionCtx, cancel := context.WithCancel(ctx)
	session := &Session{agent: a, ctx: sessionCtx, cancel: cancel, events: make(chan core.Event, 64)}
	session.alive.Store(true)
	session.id.Store(sessionID)
	return session, nil
}

func (a *Agent) callJSON(ctx context.Context, tool string, arguments any) (json.RawMessage, error) {
	result, err := a.bridge.Call(ctx, tool, arguments)
	if err != nil {
		return nil, fmt.Errorf("codex app: %s: %w", tool, err)
	}
	var envelope struct {
		ContentItems []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"contentItems"`
		Success bool `json:"success"`
	}
	if err := json.Unmarshal(result, &envelope); err != nil {
		return nil, fmt.Errorf("codex app: decode %s result envelope: %w", tool, err)
	}
	var texts []string
	for _, item := range envelope.ContentItems {
		if item.Type == "inputText" && strings.TrimSpace(item.Text) != "" {
			texts = append(texts, item.Text)
		}
	}
	if !envelope.Success {
		if len(texts) == 0 {
			return nil, fmt.Errorf("codex app: %s failed", tool)
		}
		return nil, fmt.Errorf("codex app: %s failed: %s", tool, strings.Join(texts, "\n"))
	}
	if len(texts) == 0 {
		return json.RawMessage(`{}`), nil
	}
	if len(texts) != 1 {
		return nil, fmt.Errorf("codex app: %s returned %d JSON content items", tool, len(texts))
	}
	if !json.Valid([]byte(texts[0])) {
		return nil, fmt.Errorf("codex app: %s returned non-JSON content", tool)
	}
	return json.RawMessage(texts[0]), nil
}

func unixTime(value int64) time.Time {
	if value <= 0 {
		return time.Time{}
	}
	return time.Unix(value, 0)
}

var _ core.Agent = (*Agent)(nil)
var _ core.AgentProjectCatalog = (*Agent)(nil)
var _ core.AgentSessionReader = (*Agent)(nil)
var _ core.AgentSessionWaiter = (*Agent)(nil)
var _ core.AgentSessionCreator = (*Agent)(nil)
var _ core.AgentSessionMetadataController = (*Agent)(nil)
var _ core.AgentSessionCapabilityCatalog = (*Agent)(nil)
var _ core.AuthoritativeSessionHistory = (*Agent)(nil)
