package remotenative

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/chenhg5/cc-connect/core"
	"github.com/chenhg5/cc-connect/runtimeprotocol"
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

	backend := &Backend{client: server.Client(), base: server.URL, threadDevices: make(map[string]string)}
	capabilities, err := backend.SessionCapabilities(t.Context(), "device-1")
	if err != nil {
		t.Fatal(err)
	}
	if !capabilities.Rename.Supported {
		t.Fatalf("unexpected capabilities: %#v", capabilities)
	}
}
