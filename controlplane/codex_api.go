package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/shusfun/cc-connect/core"
	"github.com/shusfun/cc-connect/runtimeprotocol"
)

const maxCodexTaskScan = 500

func (s *Server) handleCodexProjects(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, false, nil, "method not allowed")
		return
	}
	projects, err := s.broker.Catalog(r.Context())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, false, nil, err.Error())
		return
	}
	result := make([]map[string]any, 0, len(projects))
	for _, project := range projects {
		result = append(result, map[string]any{
			"device_id": project.DeviceID, "device_name": project.DeviceName,
			"project_id": project.ProjectID, "project_name": project.ProjectName,
			"host_id": project.HostID, "kind": project.Kind,
			"is_git_repository": project.Git, "available": project.Available,
			"reason": project.Reason, "order": project.Order, "online": project.Online,
		})
	}
	writeJSON(w, http.StatusOK, true, map[string]any{"projects": result}, "")
}

func (s *Server) handleCodexResource(w http.ResponseWriter, r *http.Request) {
	raw := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/codex/devices/"), "/")
	parts := strings.Split(raw, "/")
	for index := range parts {
		decoded, err := url.PathUnescape(parts[index])
		if err != nil || strings.TrimSpace(decoded) == "" {
			writeJSON(w, http.StatusNotFound, false, nil, "Codex resource not found")
			return
		}
		parts[index] = decoded
	}
	if len(parts) == 2 && parts[1] == "capabilities" {
		s.handleCodexCapabilities(w, r, parts[0])
		return
	}
	if len(parts) >= 2 && parts[1] == "automations" {
		id := ""
		if len(parts) == 3 {
			id = parts[2]
		}
		if len(parts) <= 3 {
			s.handleCodexAutomations(w, r, parts[0], id)
			return
		}
	}
	if len(parts) >= 2 && parts[1] == "plugins" {
		id, action := "", ""
		if len(parts) >= 3 {
			id = parts[2]
		}
		if len(parts) == 4 {
			action = parts[3]
		}
		if len(parts) <= 4 {
			s.handleCodexPlugins(w, r, parts[0], id, action)
			return
		}
	}
	if len(parts) >= 2 && parts[1] == "archived-tasks" {
		id := ""
		if len(parts) == 3 {
			id = parts[2]
		}
		if len(parts) <= 3 {
			s.handleCodexArchivedTasks(w, r, parts[0], id)
			return
		}
	}
	if len(parts) == 4 && parts[1] == "projects" && parts[3] == "tasks" {
		s.handleCodexProjectTasks(w, r, parts[0], parts[2])
		return
	}
	if len(parts) >= 3 && len(parts) <= 4 && parts[1] == "tasks" {
		action := ""
		if len(parts) == 4 {
			action = parts[3]
		}
		s.handleCodexTask(w, r, parts[0], parts[2], action)
		return
	}
	writeJSON(w, http.StatusNotFound, false, nil, "Codex resource not found")
}

func (s *Server) handleCodexProjectTasks(w http.ResponseWriter, r *http.Request, deviceID, projectID string) {
	project, err := s.codexProject(r.Context(), deviceID, projectID)
	if err != nil {
		writeCodexError(w, err)
		return
	}
	switch r.Method {
	case http.MethodGet:
		limit, err := codexLimit(r.URL.Query().Get("limit"), 5, 50)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
			return
		}
		page, err := s.codexTaskPage(r.Context(), project, r.URL.Query().Get("cursor"), limit)
		if err != nil {
			writeCodexError(w, err)
			return
		}
		for index := range page.Sessions {
			sanitizeCodexTask(&page.Sessions[index], project)
		}
		writeJSON(w, http.StatusOK, true, page, "")
	case http.MethodPost:
		var request struct {
			Prompt   string `json:"prompt"`
			Title    string `json:"title,omitempty"`
			UseLocal bool   `json:"use_local"`
		}
		if err := decodeRequest(r, &request); err != nil {
			writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
			return
		}
		if strings.TrimSpace(request.Prompt) == "" {
			writeJSON(w, http.StatusBadRequest, false, nil, "prompt is required")
			return
		}
		capabilities, err := s.codexCapabilities(r.Context(), project.DeviceID)
		if err != nil {
			writeCodexError(w, err)
			return
		}
		if !capabilities.Create.Supported {
			writeJSON(w, http.StatusConflict, false, nil, capabilities.Create.Reason)
			return
		}
		payload, _ := runtimeprotocol.MarshalPayload(core.AgentSessionCreateRequest{
			ProjectID: project.ProjectID, Prompt: request.Prompt, Title: request.Title, UseLocal: request.UseLocal,
		})
		raw, err := s.broker.ResolveAndCall(r.Context(), runtimeprotocol.InternalRequest{
			DeviceID: project.DeviceID, Method: runtimeprotocol.MethodTaskCreate,
			Resource: runtimeprotocol.Resource{ProjectRef: project.Ref}, Payload: payload,
		})
		if err != nil {
			writeCodexMutationError(w, err)
			return
		}
		var task core.AgentSessionInfo
		if err := strictJSON(raw, &task); err != nil {
			writeJSON(w, http.StatusBadGateway, false, nil, err.Error())
			return
		}
		sanitizeCodexTask(&task, project)
		writeJSON(w, http.StatusCreated, true, task, "")
	default:
		writeJSON(w, http.StatusMethodNotAllowed, false, nil, "GET or POST only")
	}
}

func (s *Server) handleCodexTask(w http.ResponseWriter, r *http.Request, deviceID, taskID, action string) {
	projectID := strings.TrimSpace(r.URL.Query().Get("project_id"))
	hostID := strings.TrimSpace(r.URL.Query().Get("host_id"))
	if projectID == "" {
		writeJSON(w, http.StatusBadRequest, false, nil, "project_id is required")
		return
	}
	project, err := s.codexProject(r.Context(), deviceID, projectID)
	if err != nil {
		writeCodexError(w, err)
		return
	}
	task, err := s.findCodexTask(r.Context(), project, taskID, hostID)
	if err != nil {
		writeCodexError(w, err)
		return
	}
	switch action {
	case "":
		if r.Method == http.MethodGet {
			s.readCodexTask(w, r, project, task)
			return
		}
		if r.Method == http.MethodPatch {
			s.patchCodexTask(w, r, project, task)
			return
		}
	case "wait":
		if r.Method == http.MethodGet {
			s.waitCodexTask(w, r, project, task)
			return
		}
	case "messages":
		if r.Method == http.MethodPost {
			s.sendCodexTaskMessage(w, r, project, task)
			return
		}
	}
	writeJSON(w, http.StatusMethodNotAllowed, false, nil, "method not allowed")
}

func (s *Server) readCodexTask(w http.ResponseWriter, r *http.Request, project CatalogWorkspace, task core.AgentSessionInfo) {
	limit, err := codexLimit(r.URL.Query().Get("limit"), 10, 10)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
		return
	}
	payload, _ := runtimeprotocol.MarshalPayload(runtimeprotocol.TaskReadRequest{
		TaskRef: runtimeprotocol.TaskRef{TaskID: task.ID, HostID: task.HostID},
		Cursor:  r.URL.Query().Get("cursor"), Limit: limit,
	})
	raw, err := s.callCodexTask(r.Context(), project, task.ID, runtimeprotocol.MethodTaskRead, payload)
	if err != nil {
		writeCodexError(w, err)
		return
	}
	var snapshot core.AgentTaskSnapshot
	if err := strictJSON(raw, &snapshot); err != nil {
		writeJSON(w, http.StatusBadGateway, false, nil, err.Error())
		return
	}
	sanitizeCodexTask(&snapshot.Task, project)
	writeJSON(w, http.StatusOK, true, snapshot, "")
}

func (s *Server) waitCodexTask(w http.ResponseWriter, r *http.Request, project CatalogWorkspace, task core.AgentSessionInfo) {
	timeout, err := strconv.Atoi(firstNonEmpty(r.URL.Query().Get("timeout_ms"), "30000"))
	if err != nil || timeout < 0 || timeout > 120000 {
		writeJSON(w, http.StatusBadRequest, false, nil, "timeout_ms must be between 0 and 120000")
		return
	}
	payload, _ := runtimeprotocol.MarshalPayload(runtimeprotocol.TaskWaitRequest{
		TaskRef: runtimeprotocol.TaskRef{TaskID: task.ID, HostID: task.HostID},
		Cursor:  r.URL.Query().Get("cursor"), TimeoutMS: int64(timeout),
	})
	raw, err := s.callCodexTask(r.Context(), project, task.ID, runtimeprotocol.MethodTaskWait, payload)
	if err != nil {
		writeCodexError(w, err)
		return
	}
	var snapshot core.AgentTaskSnapshot
	if err := strictJSON(raw, &snapshot); err != nil {
		writeJSON(w, http.StatusBadGateway, false, nil, err.Error())
		return
	}
	sanitizeCodexTask(&snapshot.Task, project)
	writeJSON(w, http.StatusOK, true, snapshot, "")
}

func (s *Server) sendCodexTaskMessage(w http.ResponseWriter, r *http.Request, project CatalogWorkspace, task core.AgentSessionInfo) {
	var request struct {
		Prompt    string `json:"prompt"`
		MessageID string `json:"message_id,omitempty"`
	}
	if err := decodeRequest(r, &request); err != nil {
		writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
		return
	}
	if strings.TrimSpace(request.Prompt) == "" {
		writeJSON(w, http.StatusBadRequest, false, nil, "prompt is required")
		return
	}
	if request.MessageID == "" {
		value, err := secureToken(18)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, false, nil, err.Error())
			return
		}
		request.MessageID = "web_" + value
	}
	payload, _ := runtimeprotocol.MarshalPayload(runtimeprotocol.TaskSendRequest{
		TaskRef: runtimeprotocol.TaskRef{TaskID: task.ID, HostID: task.HostID},
		Prompt:  request.Prompt, MessageID: request.MessageID,
	})
	raw, err := s.callCodexTask(r.Context(), project, task.ID, runtimeprotocol.MethodTaskSend, payload)
	if err != nil {
		if !strings.Contains(strings.ToLower(err.Error()), "unknown") {
			details, _ := json.Marshal(map[string]string{"device_id": project.DeviceID, "project_id": project.ProjectID, "task_id": task.ID, "host_id": task.HostID})
			_ = s.store.RecordAudit(r.Context(), "runtime:"+project.DeviceID, "task_failed", "task:"+task.ID, "failed", details)
		}
		writeCodexMutationError(w, err)
		return
	}
	var result runtimeprotocol.TaskSendResult
	if err := strictJSON(raw, &result); err != nil {
		writeJSON(w, http.StatusBadGateway, false, nil, err.Error())
		return
	}
	details, _ := json.Marshal(map[string]string{"device_id": project.DeviceID, "project_id": project.ProjectID, "task_id": task.ID, "host_id": task.HostID})
	_ = s.store.RecordAudit(r.Context(), "runtime:"+project.DeviceID, "task_completed", "task:"+task.ID, "succeeded", details)
	writeJSON(w, http.StatusOK, true, result, "")
}

func (s *Server) patchCodexTask(w http.ResponseWriter, r *http.Request, project CatalogWorkspace, task core.AgentSessionInfo) {
	var patch core.AgentSessionMetadataPatch
	if err := decodeRequest(r, &patch); err != nil {
		writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
		return
	}
	count := 0
	if patch.Title != nil {
		count++
		value := strings.TrimSpace(*patch.Title)
		if value == "" {
			writeJSON(w, http.StatusBadRequest, false, nil, "title must not be empty")
			return
		}
		patch.Title = &value
	}
	if patch.Pinned != nil {
		count++
	}
	if patch.Archived != nil {
		count++
	}
	if count != 1 {
		writeJSON(w, http.StatusBadRequest, false, nil, "exactly one of title, pinned, or archived is required")
		return
	}
	capabilities, err := s.codexCapabilities(r.Context(), project.DeviceID)
	if err != nil {
		writeCodexError(w, err)
		return
	}
	capability := capabilities.Rename
	if patch.Pinned != nil {
		capability = capabilities.Pin
	}
	if patch.Archived != nil {
		capability = capabilities.Archive
	}
	if !capability.Supported {
		writeJSON(w, http.StatusConflict, false, nil, capability.Reason)
		return
	}
	payload, _ := runtimeprotocol.MarshalPayload(struct {
		TaskID string                         `json:"task_id"`
		HostID string                         `json:"host_id,omitempty"`
		Patch  core.AgentSessionMetadataPatch `json:"patch"`
	}{TaskID: task.ID, HostID: task.HostID, Patch: patch})
	if _, err := s.callCodexTask(r.Context(), project, task.ID, runtimeprotocol.MethodTaskMetadata, payload); err != nil {
		writeCodexMutationError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, true, map[string]any{"updated": true}, "")
}

func (s *Server) handleCodexCapabilities(w http.ResponseWriter, r *http.Request, deviceID string) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, false, nil, "method not allowed")
		return
	}
	capabilities, err := s.codexCapabilities(r.Context(), deviceID)
	if err != nil {
		writeCodexError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, true, capabilities, "")
}

func (s *Server) codexCapabilities(ctx context.Context, deviceID string) (core.AgentSessionCapabilities, error) {
	raw, err := s.broker.ResolveAndCall(ctx, runtimeprotocol.InternalRequest{DeviceID: deviceID, Method: runtimeprotocol.MethodCapabilityList})
	if err != nil {
		return core.AgentSessionCapabilities{}, err
	}
	var capabilities core.AgentSessionCapabilities
	if err := strictJSON(raw, &capabilities); err != nil {
		return core.AgentSessionCapabilities{}, err
	}
	return capabilities, nil
}

func (s *Server) codexProject(ctx context.Context, deviceID, projectID string) (CatalogWorkspace, error) {
	projects, err := s.broker.Catalog(ctx)
	if err != nil {
		return CatalogWorkspace{}, err
	}
	for _, project := range projects {
		if project.DeviceID == deviceID && project.ProjectID == projectID {
			if !project.Online || !project.Available {
				return CatalogWorkspace{}, fmt.Errorf("codex project unavailable: %s", project.Reason)
			}
			return project, nil
		}
	}
	return CatalogWorkspace{}, errors.New("Codex project not found")
}

func (s *Server) codexTaskPage(ctx context.Context, project CatalogWorkspace, cursor string, limit int) (core.AgentSessionPage, error) {
	payload, _ := runtimeprotocol.MarshalPayload(runtimeprotocol.TaskListRequest{ProjectID: project.ProjectID, Cursor: cursor, Limit: limit})
	raw, err := s.broker.ResolveAndCall(ctx, runtimeprotocol.InternalRequest{
		DeviceID: project.DeviceID, Method: runtimeprotocol.MethodTaskList,
		Resource: runtimeprotocol.Resource{ProjectRef: project.Ref}, Payload: payload,
	})
	if err != nil {
		return core.AgentSessionPage{}, err
	}
	var page core.AgentSessionPage
	if err := strictJSON(raw, &page); err != nil {
		return core.AgentSessionPage{}, err
	}
	return page, nil
}

func (s *Server) findCodexTask(ctx context.Context, project CatalogWorkspace, taskID, hostID string) (core.AgentSessionInfo, error) {
	cursor := ""
	var matched *core.AgentSessionInfo
	for scanned := 0; scanned < maxCodexTaskScan; {
		page, err := s.codexTaskPage(ctx, project, cursor, 50)
		if err != nil {
			return core.AgentSessionInfo{}, err
		}
		for _, task := range page.Sessions {
			if task.ID != taskID || task.ProjectID != project.ProjectID || (hostID != "" && task.HostID != hostID) {
				continue
			}
			if matched != nil && matched.HostID != task.HostID {
				return core.AgentSessionInfo{}, errors.New("Codex task host is ambiguous; host_id is required")
			}
			candidate := task
			matched = &candidate
		}
		scanned += len(page.Sessions)
		if !page.HasMore || page.Cursor == "" || len(page.Sessions) == 0 {
			break
		}
		cursor = page.Cursor
	}
	if matched != nil {
		return *matched, nil
	}
	return core.AgentSessionInfo{}, errors.New("Codex task does not belong to the requested device, host, and project")
}

func (s *Server) callCodexTask(ctx context.Context, project CatalogWorkspace, taskID string, method runtimeprotocol.Method, payload json.RawMessage) (json.RawMessage, error) {
	return s.broker.ResolveAndCall(ctx, runtimeprotocol.InternalRequest{
		DeviceID: project.DeviceID, Method: method,
		Resource: runtimeprotocol.Resource{ProjectRef: project.Ref, TaskID: taskID}, Payload: payload,
	})
}

func sanitizeCodexTask(task *core.AgentSessionInfo, project CatalogWorkspace) {
	task.ProjectID = project.ProjectID
	task.ProjectName = project.ProjectName
	task.CWD = ""
}

func codexLimit(raw string, fallback, maximum int) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 1 || value > maximum {
		return 0, fmt.Errorf("limit must be between 1 and %d", maximum)
	}
	return value, nil
}

func writeCodexMutationError(w http.ResponseWriter, err error) {
	message := strings.TrimSpace(err.Error())
	if strings.Contains(message, "device_offline") || strings.Contains(message, "send runtime request") || errors.Is(err, context.DeadlineExceeded) {
		writeJSON(w, http.StatusBadGateway, false, nil, "result_unknown: "+message)
		return
	}
	writeCodexError(w, err)
}

func writeCodexError(w http.ResponseWriter, err error) {
	message := strings.TrimSpace(err.Error())
	status := http.StatusBadGateway
	switch {
	case strings.Contains(message, "not found"), strings.Contains(message, "does not belong"):
		status = http.StatusNotFound
	case strings.Contains(message, "unavailable"), strings.Contains(message, "device_offline"):
		status = http.StatusServiceUnavailable
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, context.Canceled):
		status = http.StatusGatewayTimeout
	}
	writeJSON(w, status, false, nil, message)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
