package remotenative

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/shusfun/cc-connect/core"
	"github.com/shusfun/cc-connect/runtimeprotocol"
)

func TestSessionCapabilitiesUseRequestedRuntimeHost(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request runtimeprotocol.InternalRequest
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		if request.DeviceID != "device-1" || request.Method != runtimeprotocol.MethodCapabilityList {
			t.Errorf("unexpected request: %#v", request)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "data": core.AgentSessionCapabilities{
			Rename: core.AgentSessionCapability{Supported: true},
		}})
	}))
	defer server.Close()

	backend := &Backend{client: server.Client(), base: server.URL, threadDevices: make(map[taskKey]taskLocation)}
	capabilities, err := backend.SessionCapabilities(t.Context(), "device-1")
	if err != nil {
		t.Fatal(err)
	}
	if !capabilities.Rename.Supported {
		t.Fatalf("unexpected capabilities: %#v", capabilities)
	}
}

func TestListAndReadSessionsTranslateRuntimeAndNativeHosts(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/runtime/v1/catalog":
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "data": []map[string]any{{
				"device_id": "device-1", "project_id": "project-1", "project_name": "Project", "online": true, "available": true,
			}}})
		case "/runtime/v1/rpc":
			var request runtimeprotocol.InternalRequest
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Fatal(err)
			}
			switch request.Method {
			case runtimeprotocol.MethodTaskList:
				_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "data": core.AgentSessionPage{
					Sessions: []core.AgentSessionInfo{{ID: "task-1", HostID: "local", ProjectID: "project-1"}},
				}})
			case runtimeprotocol.MethodTaskRead:
				var taskRequest runtimeprotocol.TaskReadRequest
				if err := json.NewDecoder(bytes.NewReader(request.Payload)).Decode(&taskRequest); err != nil {
					t.Fatal(err)
				}
				if request.DeviceID != "device-1" || taskRequest.HostID != "local" {
					t.Errorf("task request = %#v, device = %q", taskRequest, request.DeviceID)
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "data": core.AgentTaskSnapshot{
					Task: core.AgentSessionInfo{ID: "task-1", HostID: "local", ProjectID: "project-1"},
				}})
			default:
				t.Fatalf("unexpected method: %s", request.Method)
			}
		default:
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
	}))
	defer server.Close()

	backend := &Backend{client: server.Client(), base: server.URL, threadDevices: make(map[taskKey]taskLocation)}
	sessions, err := backend.ListSessions(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if len(sessions) != 1 || sessions[0].HostID != "device-1" {
		t.Fatalf("sessions = %#v", sessions)
	}
	snapshot, err := backend.ReadSession(t.Context(), "task-1", "device-1", "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Session.HostID != "device-1" {
		t.Fatalf("snapshot host = %q, want device-1", snapshot.Session.HostID)
	}
}

func TestTaskLocationRequiresHostForDuplicateTaskIDs(t *testing.T) {
	backend := &Backend{threadDevices: map[taskKey]taskLocation{
		{deviceID: "device-1", taskID: "same-task"}: {deviceID: "device-1", nativeHostID: "local"},
		{deviceID: "device-2", taskID: "same-task"}: {deviceID: "device-2", nativeHostID: "remote"},
	}}

	location, found, err := backend.cachedTaskLocation(taskKey{deviceID: "device-2", taskID: "same-task"})
	if err != nil || !found || location.deviceID != "device-2" || location.nativeHostID != "remote" {
		t.Fatalf("location = %#v, found = %v, err = %v", location, found, err)
	}
	if _, _, err := backend.cachedTaskLocation(taskKey{taskID: "same-task"}); err == nil || !strings.Contains(err.Error(), "host_id is required") {
		t.Fatalf("ambiguous lookup error = %v", err)
	}
}
