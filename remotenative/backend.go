package remotenative

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/shusfun/cc-connect/controlplane"
	"github.com/shusfun/cc-connect/core"
	"github.com/shusfun/cc-connect/runtimeprotocol"
)

// Backend exposes a paired Desktop App Runtime as a regular core.Agent.
// It never launches a local CLI process and never takes ownership of App tasks.
type Backend struct {
	client        *http.Client
	base          string
	mu            sync.RWMutex
	threadDevices map[taskKey]taskLocation
}

type taskKey struct {
	deviceID string
	taskID   string
}

type taskLocation struct {
	deviceID     string
	nativeHostID string
}

func New(socketPath string) (*Backend, error) {
	if strings.TrimSpace(socketPath) == "" {
		return nil, errors.New("remote codex app: runtime socket is required")
	}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socketPath)
	}}
	return &Backend{client: &http.Client{Transport: transport}, base: "http://cc-connect-control", threadDevices: make(map[taskKey]taskLocation)}, nil
}

func (b *Backend) Name() string                 { return "codexapp" }
func (b *Backend) Stop() error                  { return nil }
func (b *Backend) AuthoritativeSessionHistory() {}

func (b *Backend) ListProjects(ctx context.Context) ([]core.AgentProjectInfo, error) {
	workspaces, err := b.catalog(ctx)
	if err != nil {
		return nil, err
	}
	result := make([]core.AgentProjectInfo, 0, len(workspaces))
	for _, workspace := range workspaces {
		result = append(result, core.AgentProjectInfo{ID: workspace.ProjectID, Name: workspace.ProjectName, HostID: workspace.DeviceID, Kind: "local", IsGitRepository: true})
	}
	return result, nil
}

func (b *Backend) ListSessions(ctx context.Context) ([]core.AgentSessionInfo, error) {
	workspaces, err := b.catalog(ctx)
	if err != nil {
		return nil, err
	}
	result := make([]core.AgentSessionInfo, 0)
	for _, workspace := range workspaces {
		if !workspace.Online || !workspace.Available {
			continue
		}
		cursor := ""
		for {
			var page core.AgentSessionPage
			request := runtimeprotocol.TaskListRequest{ProjectID: workspace.ProjectID, Cursor: cursor, Limit: 50}
			if err := b.rpc(ctx, workspace.DeviceID, runtimeprotocol.MethodTaskList, request, &page); err != nil {
				return nil, err
			}
			for index := range page.Sessions {
				b.rememberTask(&page.Sessions[index], workspace.DeviceID)
			}
			result = append(result, page.Sessions...)
			if !page.HasMore || page.Cursor == "" {
				break
			}
			cursor = page.Cursor
		}
	}
	return result, nil
}

func (b *Backend) ListSessionPage(ctx context.Context, request core.AgentSessionListRequest) (core.AgentSessionPage, error) {
	workspaces, err := b.catalog(ctx)
	if err != nil {
		return core.AgentSessionPage{}, err
	}
	var selected *controlplane.CatalogWorkspace
	for index := range workspaces {
		workspace := &workspaces[index]
		if workspace.ProjectID != request.ProjectID || !workspace.Online || !workspace.Available {
			continue
		}
		if selected != nil && selected.DeviceID != workspace.DeviceID {
			return core.AgentSessionPage{}, fmt.Errorf("remote codex app: project %s exists on multiple Runtime devices", request.ProjectID)
		}
		selected = workspace
	}
	if selected == nil {
		return core.AgentSessionPage{}, fmt.Errorf("remote codex app: project not found: %s", request.ProjectID)
	}
	var result core.AgentSessionPage
	err = b.rpc(ctx, selected.DeviceID, runtimeprotocol.MethodTaskList, runtimeprotocol.TaskListRequest{
		ProjectID: request.ProjectID, Cursor: request.Cursor, Limit: request.Limit,
	}, &result)
	if err != nil {
		return core.AgentSessionPage{}, err
	}
	for index := range result.Sessions {
		b.rememberTask(&result.Sessions[index], selected.DeviceID)
	}
	return result, nil
}

func (b *Backend) ReadSession(ctx context.Context, sessionID, hostID, cursor string, limit int) (core.AgentSessionSnapshot, error) {
	snapshot, err := b.ReadTask(ctx, sessionID, hostID, cursor, limit)
	if err != nil {
		return core.AgentSessionSnapshot{}, err
	}
	return flattenTaskSnapshot(snapshot), nil
}

func (b *Backend) ReadTask(ctx context.Context, sessionID, hostID, cursor string, limit int) (core.AgentTaskSnapshot, error) {
	location, err := b.locationForTask(ctx, sessionID, hostID)
	if err != nil {
		return core.AgentTaskSnapshot{}, err
	}
	var result core.AgentTaskSnapshot
	err = b.rpc(ctx, location.deviceID, runtimeprotocol.MethodTaskRead, runtimeprotocol.TaskReadRequest{TaskRef: runtimeprotocol.TaskRef{TaskID: sessionID, HostID: location.nativeHostID}, Cursor: cursor, Limit: limit}, &result)
	if err == nil {
		b.rememberTask(&result.Task, location.deviceID)
	}
	return result, err
}

func (b *Backend) WaitSession(ctx context.Context, sessionID, hostID, cursor string, timeout time.Duration) (core.AgentSessionSnapshot, error) {
	snapshot, err := b.WaitTask(ctx, sessionID, hostID, cursor, timeout)
	if err != nil {
		return core.AgentSessionSnapshot{}, err
	}
	return flattenTaskSnapshot(snapshot), nil
}

func (b *Backend) WaitTask(ctx context.Context, sessionID, hostID, cursor string, timeout time.Duration) (core.AgentTaskSnapshot, error) {
	location, err := b.locationForTask(ctx, sessionID, hostID)
	if err != nil {
		return core.AgentTaskSnapshot{}, err
	}
	var result core.AgentTaskSnapshot
	err = b.rpc(ctx, location.deviceID, runtimeprotocol.MethodTaskWait, runtimeprotocol.TaskWaitRequest{TaskRef: runtimeprotocol.TaskRef{TaskID: sessionID, HostID: location.nativeHostID}, Cursor: cursor, TimeoutMS: timeout.Milliseconds()}, &result)
	if err == nil {
		b.rememberTask(&result.Task, location.deviceID)
	}
	return result, err
}

func flattenTaskSnapshot(snapshot core.AgentTaskSnapshot) core.AgentSessionSnapshot {
	history := make([]core.HistoryEntry, 0)
	for _, turn := range snapshot.Turns {
		for _, item := range turn.Items {
			switch item.Type {
			case "user_message":
				parts := make([]string, 0, len(item.Content))
				for _, part := range item.Content {
					if part.Type == "text" && strings.TrimSpace(part.Text) != "" {
						parts = append(parts, part.Text)
					}
				}
				if len(parts) > 0 {
					history = append(history, core.HistoryEntry{Role: "user", Content: strings.Join(parts, "\n"), Timestamp: turn.StartedAt})
				}
			case "agent_message":
				if strings.TrimSpace(item.Text) != "" {
					history = append(history, core.HistoryEntry{Role: "assistant", Content: item.Text, Timestamp: turn.StartedAt})
				}
			}
		}
	}
	task := snapshot.Task
	task.MessageCount = len(history)
	return core.AgentSessionSnapshot{Session: task, History: history, Cursor: snapshot.Page.Cursor, WaitCursor: snapshot.WaitCursor, HasMore: snapshot.Page.HasMore}
}

func (b *Backend) CreateSession(ctx context.Context, request core.AgentSessionCreateRequest) (core.AgentSessionInfo, error) {
	workspaces, err := b.catalog(ctx)
	if err != nil {
		return core.AgentSessionInfo{}, err
	}
	for _, workspace := range workspaces {
		if workspace.ProjectID != request.ProjectID {
			continue
		}
		var result core.AgentSessionInfo
		if err := b.rpc(ctx, workspace.DeviceID, runtimeprotocol.MethodTaskCreate, request, &result); err != nil {
			return result, err
		}
		b.rememberTask(&result, workspace.DeviceID)
		return result, nil
	}
	return core.AgentSessionInfo{}, fmt.Errorf("remote codex app: project not found: %s", request.ProjectID)
}

func (b *Backend) UpdateSessionMetadata(ctx context.Context, sessionID, hostID string, patch core.AgentSessionMetadataPatch) error {
	location, err := b.locationForTask(ctx, sessionID, hostID)
	if err != nil {
		return err
	}
	request := struct {
		TaskID string                         `json:"task_id"`
		HostID string                         `json:"host_id,omitempty"`
		Patch  core.AgentSessionMetadataPatch `json:"patch"`
	}{sessionID, location.nativeHostID, patch}
	return b.rpc(ctx, location.deviceID, runtimeprotocol.MethodTaskMetadata, request, nil)
}

func (b *Backend) SessionCapabilities(ctx context.Context, hostID string) (core.AgentSessionCapabilities, error) {
	deviceID := strings.TrimSpace(hostID)
	if deviceID == "" {
		workspaces, err := b.catalog(ctx)
		if err != nil {
			return core.AgentSessionCapabilities{}, err
		}
		active := make(map[string]struct{})
		for _, workspace := range workspaces {
			if workspace.Online && workspace.Available {
				active[workspace.DeviceID] = struct{}{}
			}
		}
		if len(active) != 1 {
			return core.AgentSessionCapabilities{}, fmt.Errorf("remote codex app: host_id is required when %d Runtime hosts are available", len(active))
		}
		for candidate := range active {
			deviceID = candidate
		}
	}
	var result core.AgentSessionCapabilities
	if err := b.rpc(ctx, deviceID, runtimeprotocol.MethodCapabilityList, nil, &result); err != nil {
		return core.AgentSessionCapabilities{}, err
	}
	return result, nil
}

func (b *Backend) StartSession(ctx context.Context, sessionID string) (core.AgentSession, error) {
	sessionCtx, cancel := context.WithCancel(ctx)
	session := &remoteSession{backend: b, ctx: sessionCtx, cancel: cancel, events: make(chan core.Event, 16), id: sessionID}
	session.alive.Store(true)
	return session, nil
}

func (b *Backend) locationForTask(ctx context.Context, sessionID, deviceID string) (taskLocation, error) {
	key := taskKey{deviceID: strings.TrimSpace(deviceID), taskID: sessionID}
	if location, found, err := b.cachedTaskLocation(key); found || err != nil {
		return location, err
	}
	if _, err := b.ListSessions(ctx); err != nil {
		return taskLocation{}, err
	}
	location, found, err := b.cachedTaskLocation(key)
	if err != nil {
		return taskLocation{}, err
	}
	if !found {
		return taskLocation{}, fmt.Errorf("remote codex app: task not found: host=%s task=%s", deviceID, sessionID)
	}
	return location, nil
}

func (b *Backend) cachedTaskLocation(key taskKey) (taskLocation, bool, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if key.deviceID != "" {
		location, found := b.threadDevices[key]
		return location, found, nil
	}
	var match taskLocation
	for candidate, location := range b.threadDevices {
		if candidate.taskID != key.taskID {
			continue
		}
		if match.deviceID != "" && match.deviceID != location.deviceID {
			return taskLocation{}, false, fmt.Errorf("remote codex app: host_id is required because task %s exists on multiple Runtime hosts", key.taskID)
		}
		match = location
	}
	return match, match.deviceID != "", nil
}

func (b *Backend) rememberTask(session *core.AgentSessionInfo, deviceID string) {
	if session == nil || session.ID == "" {
		return
	}
	location := taskLocation{deviceID: deviceID, nativeHostID: session.HostID}
	key := taskKey{deviceID: deviceID, taskID: session.ID}
	b.mu.Lock()
	if location.nativeHostID == "" {
		location.nativeHostID = b.threadDevices[key].nativeHostID
	}
	b.threadDevices[key] = location
	b.mu.Unlock()
	session.HostID = deviceID
}

func (b *Backend) catalog(ctx context.Context) ([]controlplane.CatalogWorkspace, error) {
	var result []controlplane.CatalogWorkspace
	if err := b.get(ctx, "/runtime/v1/catalog", &result); err != nil {
		return nil, err
	}
	return result, nil
}

func (b *Backend) rpc(ctx context.Context, deviceID string, method runtimeprotocol.Method, request any, response any) error {
	var payload json.RawMessage
	if request != nil {
		encoded, err := json.Marshal(request)
		if err != nil {
			return err
		}
		payload = encoded
	}
	body, err := json.Marshal(runtimeprotocol.InternalRequest{DeviceID: deviceID, Method: method, Payload: payload})
	if err != nil {
		return err
	}
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, b.base+"/runtime/v1/rpc", bytes.NewReader(body))
	if err != nil {
		return err
	}
	httpRequest.Header.Set("Content-Type", "application/json")
	httpResponse, err := b.client.Do(httpRequest)
	if err != nil {
		return fmt.Errorf("remote codex app: call control: %w", err)
	}
	defer func() { _ = httpResponse.Body.Close() }()
	return decodeControlResponse(httpResponse, response)
}

func (b *Backend) get(ctx context.Context, path string, response any) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, b.base+path, nil)
	if err != nil {
		return err
	}
	result, err := b.client.Do(request)
	if err != nil {
		return fmt.Errorf("remote codex app: read control: %w", err)
	}
	defer func() { _ = result.Body.Close() }()
	return decodeControlResponse(result, response)
}

func decodeControlResponse(response *http.Response, target any) error {
	var envelope struct {
		OK    bool            `json:"ok"`
		Data  json.RawMessage `json:"data"`
		Error string          `json:"error"`
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 8<<20))
	if err := decoder.Decode(&envelope); err != nil {
		return fmt.Errorf("remote codex app: decode control response: %w", err)
	}
	if !envelope.OK || response.StatusCode >= 400 {
		return fmt.Errorf("remote codex app: %s", envelope.Error)
	}
	if target == nil || len(envelope.Data) == 0 || bytes.Equal(envelope.Data, []byte("null")) {
		return nil
	}
	if err := json.Unmarshal(envelope.Data, target); err != nil {
		return fmt.Errorf("remote codex app: decode response data: %w", err)
	}
	return nil
}

var _ core.Agent = (*Backend)(nil)
var _ core.AgentProjectCatalog = (*Backend)(nil)
var _ core.AgentSessionPageLister = (*Backend)(nil)
var _ core.AgentTaskReader = (*Backend)(nil)
var _ core.AgentTaskWaiter = (*Backend)(nil)
var _ core.AgentSessionReader = (*Backend)(nil)
var _ core.AgentSessionWaiter = (*Backend)(nil)
var _ core.AgentSessionCreator = (*Backend)(nil)
var _ core.AgentSessionMetadataController = (*Backend)(nil)
var _ core.AgentSessionCapabilityCatalog = (*Backend)(nil)
var _ core.AuthoritativeSessionHistory = (*Backend)(nil)

func (b *Backend) HTTPClientForTests() *http.Client { return b.client }
