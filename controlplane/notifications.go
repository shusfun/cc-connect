package controlplane

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type publicNotification struct {
	ID         int64     `json:"id"`
	Type       string    `json:"type"`
	Outcome    string    `json:"outcome"`
	OccurredAt time.Time `json:"occurred_at"`
	Href       string    `json:"href,omitempty"`
	Read       bool      `json:"read"`
}

func (s *Server) handleNotifications(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, false, nil, "GET only")
		return
	}
	after, err := strconv.ParseInt(firstNonEmpty(r.URL.Query().Get("after"), "0"), 10, 64)
	if err != nil || after < 0 {
		writeJSON(w, http.StatusBadRequest, false, nil, "after must be a non-negative integer")
		return
	}
	limit, err := codexLimit(r.URL.Query().Get("limit"), 30, 100)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
		return
	}
	page, err := s.store.Notifications(r.Context(), after, limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, false, nil, err.Error())
		return
	}
	items := make([]publicNotification, 0, len(page.Events))
	for _, event := range page.Events {
		item := publicNotification{ID: event.ID, Type: event.Action, Outcome: event.Outcome, OccurredAt: event.OccurredAt, Read: event.ID <= page.ReadCursor}
		var details struct {
			DeviceID  string `json:"device_id"`
			ProjectID string `json:"project_id"`
			TaskID    string `json:"task_id"`
		}
		_ = json.Unmarshal(event.Details, &details)
		if details.DeviceID != "" && details.ProjectID != "" && details.TaskID != "" {
			item.Href = "/tasks/" + pathSegment(details.DeviceID) + "/" + pathSegment(details.ProjectID) + "/" + pathSegment(details.TaskID)
		} else if strings.HasPrefix(event.Action, "runtime_") || strings.HasPrefix(event.Action, "device_") {
			item.Href = "/settings/devices"
		} else if strings.Contains(event.Action, "update") || strings.HasPrefix(event.Action, "deploy_") {
			item.Href = "/settings/updates"
		}
		items = append(items, item)
	}
	writeJSON(w, http.StatusOK, true, map[string]any{"items": items, "read_cursor": page.ReadCursor, "unread": page.Unread}, "")
}

func (s *Server) handleNotificationRead(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, false, nil, "POST only")
		return
	}
	var request struct {
		ThroughID int64 `json:"through_id"`
	}
	if err := decodeRequest(r, &request); err != nil {
		writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
		return
	}
	if err := s.store.MarkNotificationsRead(r.Context(), request.ThroughID); err != nil {
		writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, true, map[string]int64{"read_cursor": request.ThroughID}, "")
}

func pathSegment(value string) string {
	return url.PathEscape(value)
}
