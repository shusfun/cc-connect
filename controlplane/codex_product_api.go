package controlplane

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/shusfun/cc-connect/core"
	"github.com/shusfun/cc-connect/runtimeprotocol"
)

func (s *Server) handleCodexSearch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, false, nil, "GET only")
		return
	}
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if query == "" {
		writeJSON(w, http.StatusBadRequest, false, nil, "q is required")
		return
	}
	limit, err := codexLimit(r.URL.Query().Get("limit"), 30, 100)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
		return
	}
	projects, err := s.broker.Catalog(r.Context())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, false, nil, err.Error())
		return
	}
	byDevice := make(map[string][]CatalogWorkspace)
	for _, project := range projects {
		byDevice[project.DeviceID] = append(byDevice[project.DeviceID], project)
	}
	result := make([]core.AgentTaskSearchResult, 0, limit)
	offline := make([]map[string]string, 0)
	for deviceID, deviceProjects := range byDevice {
		if len(result) == limit {
			break
		}
		available := false
		for _, project := range deviceProjects {
			available = available || project.Online && project.Available
		}
		if !available {
			offline = append(offline, map[string]string{"device_id": deviceID, "device_name": deviceProjects[0].DeviceName, "reason": "Codex Runtime 离线"})
			continue
		}
		payload, _ := runtimeprotocol.MarshalPayload(runtimeprotocol.TaskSearchRequest{Query: query, Limit: limit - len(result)})
		raw, callErr := s.broker.ResolveAndCall(r.Context(), runtimeprotocol.InternalRequest{DeviceID: deviceID, Method: runtimeprotocol.MethodTaskSearch, Payload: payload})
		if callErr != nil {
			offline = append(offline, map[string]string{"device_id": deviceID, "device_name": deviceProjects[0].DeviceName, "reason": "Codex Runtime 暂不可用"})
			continue
		}
		var values []core.AgentTaskSearchResult
		if strictJSON(raw, &values) != nil {
			continue
		}
		for _, value := range values {
			for _, project := range deviceProjects {
				if value.Task.ProjectID != project.ProjectID {
					continue
				}
				value.DeviceID = deviceID
				sanitizeCodexTask(&value.Task, project)
				result = append(result, value)
				break
			}
			if len(result) == limit {
				break
			}
		}
	}
	writeJSON(w, http.StatusOK, true, map[string]any{"results": result, "offline_devices": offline}, "")
}

func (s *Server) handleCodexAutomations(w http.ResponseWriter, r *http.Request, deviceID, automationID string) {
	if err := s.requireOnlineCodexDevice(r.Context(), deviceID); err != nil {
		writeCodexError(w, err)
		return
	}
	switch r.Method {
	case http.MethodGet:
		if automationID != "" {
			writeJSON(w, http.StatusMethodNotAllowed, false, nil, "collection GET only")
			return
		}
		raw, err := s.broker.ResolveAndCall(r.Context(), runtimeprotocol.InternalRequest{DeviceID: deviceID, Method: runtimeprotocol.MethodAutomationList})
		if err != nil {
			writeCodexError(w, err)
			return
		}
		var values []core.AgentAutomation
		if err := strictJSON(raw, &values); err != nil {
			writeJSON(w, http.StatusBadGateway, false, nil, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, true, map[string]any{"automations": values}, "")
	case http.MethodPost, http.MethodPatch:
		var mutation core.AgentAutomationMutation
		if err := decodeRequest(r, &mutation); err != nil {
			writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
			return
		}
		method := runtimeprotocol.MethodAutomationCreate
		if r.Method == http.MethodPatch {
			if automationID == "" {
				writeJSON(w, http.StatusBadRequest, false, nil, "automation id is required")
				return
			}
			mutation.ID, method = automationID, runtimeprotocol.MethodAutomationUpdate
		} else if automationID != "" || mutation.ID != "" {
			writeJSON(w, http.StatusBadRequest, false, nil, "new automation must not include an id")
			return
		}
		if mutation.ProjectID != "" {
			if _, err := s.codexProject(r.Context(), deviceID, mutation.ProjectID); err != nil {
				writeCodexError(w, err)
				return
			}
		}
		payload, _ := runtimeprotocol.MarshalPayload(mutation)
		raw, err := s.broker.ResolveAndCall(r.Context(), runtimeprotocol.InternalRequest{DeviceID: deviceID, Method: method, Payload: payload})
		if err != nil {
			writeCodexMutationError(w, err)
			return
		}
		var value core.AgentAutomation
		if err := strictJSON(raw, &value); err != nil {
			writeJSON(w, http.StatusBadGateway, false, nil, err.Error())
			return
		}
		status := http.StatusOK
		if r.Method == http.MethodPost {
			status = http.StatusCreated
		}
		writeJSON(w, status, true, value, "")
	case http.MethodDelete:
		if automationID == "" {
			writeJSON(w, http.StatusBadRequest, false, nil, "automation id is required")
			return
		}
		payload, _ := runtimeprotocol.MarshalPayload(runtimeprotocol.AutomationDeleteRequest{ID: automationID})
		if _, err := s.broker.ResolveAndCall(r.Context(), runtimeprotocol.InternalRequest{DeviceID: deviceID, Method: runtimeprotocol.MethodAutomationDelete, Payload: payload}); err != nil {
			writeCodexMutationError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, true, map[string]bool{"deleted": true}, "")
	default:
		writeJSON(w, http.StatusMethodNotAllowed, false, nil, "method not allowed")
	}
}

func (s *Server) handleCodexPlugins(w http.ResponseWriter, r *http.Request, deviceID, pluginID, action string) {
	if err := s.requireOnlineCodexDevice(r.Context(), deviceID); err != nil {
		writeCodexError(w, err)
		return
	}
	if r.Method == http.MethodGet && pluginID == "" {
		available, _ := strconv.ParseBool(r.URL.Query().Get("available"))
		payload, _ := runtimeprotocol.MarshalPayload(runtimeprotocol.PluginListRequest{Available: available})
		raw, err := s.broker.ResolveAndCall(r.Context(), runtimeprotocol.InternalRequest{DeviceID: deviceID, Method: runtimeprotocol.MethodPluginList, Payload: payload})
		if err != nil {
			writeCodexError(w, err)
			return
		}
		var values []core.AgentPlugin
		if err := strictJSON(raw, &values); err != nil {
			writeJSON(w, http.StatusBadGateway, false, nil, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, true, map[string]any{"plugins": values}, "")
		return
	}
	if pluginID == "" {
		writeJSON(w, http.StatusBadRequest, false, nil, "plugin id is required")
		return
	}
	payload, _ := runtimeprotocol.MarshalPayload(runtimeprotocol.PluginMutationRequest{ID: pluginID})
	if r.Method == http.MethodPost && action == "install" {
		raw, err := s.broker.ResolveAndCall(r.Context(), runtimeprotocol.InternalRequest{DeviceID: deviceID, Method: runtimeprotocol.MethodPluginInstall, Payload: payload})
		if err != nil {
			writeCodexMutationError(w, err)
			return
		}
		var value core.AgentPlugin
		if err := strictJSON(raw, &value); err != nil {
			writeJSON(w, http.StatusBadGateway, false, nil, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, true, value, "")
		return
	}
	if r.Method == http.MethodDelete && action == "" {
		if _, err := s.broker.ResolveAndCall(r.Context(), runtimeprotocol.InternalRequest{DeviceID: deviceID, Method: runtimeprotocol.MethodPluginRemove, Payload: payload}); err != nil {
			writeCodexMutationError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, true, map[string]bool{"removed": true}, "")
		return
	}
	writeJSON(w, http.StatusMethodNotAllowed, false, nil, "method not allowed")
}

func (s *Server) handleCodexArchivedTasks(w http.ResponseWriter, r *http.Request, deviceID, taskID string) {
	if err := s.requireOnlineCodexDevice(r.Context(), deviceID); err != nil {
		writeCodexError(w, err)
		return
	}
	limit, err := codexLimit(r.URL.Query().Get("limit"), 50, 50)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
		return
	}
	payload, _ := runtimeprotocol.MarshalPayload(runtimeprotocol.TaskListRequest{Limit: limit})
	raw, err := s.broker.ResolveAndCall(r.Context(), runtimeprotocol.InternalRequest{DeviceID: deviceID, Method: runtimeprotocol.MethodTaskArchived, Payload: payload})
	if err != nil {
		writeCodexError(w, err)
		return
	}
	var page core.AgentSessionPage
	if err := strictJSON(raw, &page); err != nil {
		writeJSON(w, http.StatusBadGateway, false, nil, err.Error())
		return
	}
	projects, _ := s.broker.Catalog(r.Context())
	valid := make([]core.AgentSessionInfo, 0, len(page.Sessions))
	for _, task := range page.Sessions {
		for _, project := range projects {
			if project.DeviceID == deviceID && project.ProjectID == task.ProjectID {
				sanitizeCodexTask(&task, project)
				valid = append(valid, task)
				break
			}
		}
	}
	page.Sessions = valid
	if r.Method == http.MethodGet && taskID == "" {
		writeJSON(w, http.StatusOK, true, page, "")
		return
	}
	if r.Method == http.MethodPatch && taskID != "" {
		hostID := strings.TrimSpace(r.URL.Query().Get("host_id"))
		found := false
		for _, task := range valid {
			if task.ID == taskID && (hostID == "" || hostID == task.HostID) {
				hostID = task.HostID
				found = true
				break
			}
		}
		if !found {
			writeJSON(w, http.StatusNotFound, false, nil, "archived task not found on this device")
			return
		}
		archived := false
		meta, _ := runtimeprotocol.MarshalPayload(struct {
			TaskID string                         `json:"task_id"`
			HostID string                         `json:"host_id,omitempty"`
			Patch  core.AgentSessionMetadataPatch `json:"patch"`
		}{TaskID: taskID, HostID: hostID, Patch: core.AgentSessionMetadataPatch{Archived: &archived}})
		if _, err := s.broker.ResolveAndCall(r.Context(), runtimeprotocol.InternalRequest{DeviceID: deviceID, Method: runtimeprotocol.MethodTaskMetadata, Resource: runtimeprotocol.Resource{TaskID: taskID}, Payload: meta}); err != nil {
			writeCodexMutationError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, true, map[string]bool{"restored": true}, "")
		return
	}
	writeJSON(w, http.StatusMethodNotAllowed, false, nil, "method not allowed")
}

func (s *Server) requireOnlineCodexDevice(ctx context.Context, deviceID string) error {
	devices, err := s.broker.Devices(ctx)
	if err != nil {
		return err
	}
	for _, device := range devices {
		if device.ID == deviceID && device.RevokedAt == nil {
			if !device.Online {
				return errors.New("Codex device is offline")
			}
			return nil
		}
	}
	return errors.New("Codex device not found")
}
