package controlplane

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/shusfun/cc-connect/controlstore"
	"github.com/shusfun/cc-connect/runtimeprotocol"
)

func pairedCatalogDevice(t *testing.T, store *controlstore.Store, broker *Broker, name, projectID string) string {
	t.Helper()
	ctx := context.Background()
	code, err := store.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	publicKey, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	device, err := store.PairDevice(ctx, code.Code, name, publicKey)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(runtimeprotocol.ProjectCatalog{Projects: []runtimeprotocol.Project{{
		LocalRef: "local-" + projectID, ProjectID: projectID, ProjectName: "Project " + projectID, HostID: "local", Available: true,
	}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := broker.persistCatalog(device.ID, raw); err != nil {
		t.Fatal(err)
	}
	return device.ID
}

func TestCodexSearchProjectsOfflineDevicesWithoutBridgeProjects(t *testing.T) {
	store, err := controlstore.Open(filepath.Join(t.TempDir(), "control.db"), "setup")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	broker, err := NewBroker(store)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = broker.Close() })
	deviceOne := pairedCatalogDevice(t, store, broker, "Mac 1", "project-1")
	deviceTwo := pairedCatalogDevice(t, store, broker, "Mac 2", "project-2")
	server := &Server{store: store, broker: broker}

	response := httptest.NewRecorder()
	server.handleCodexSearch(response, httptest.NewRequest(http.MethodGet, "/api/v1/codex/search?q=project&limit=10", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("search status = %d, body=%s", response.Code, response.Body.String())
	}
	var envelope struct {
		Data struct {
			Results []json.RawMessage `json:"results"`
			Offline []struct {
				DeviceID string `json:"device_id"`
			} `json:"offline_devices"`
		} `json:"data"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	if len(envelope.Data.Results) != 0 || len(envelope.Data.Offline) != 2 {
		t.Fatalf("search projection = %#v", envelope.Data)
	}
	seen := map[string]bool{}
	for _, device := range envelope.Data.Offline {
		seen[device.DeviceID] = true
	}
	if !seen[deviceOne] || !seen[deviceTwo] || strings.Contains(response.Body.String(), "codex-app") {
		t.Fatalf("offline device projection = %s", response.Body.String())
	}
}

func TestCodexProductHandlersRejectCrossDeviceProjectOwnership(t *testing.T) {
	store, err := controlstore.Open(filepath.Join(t.TempDir(), "control.db"), "setup")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	broker, err := NewBroker(store)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = broker.Close() })
	deviceOne := pairedCatalogDevice(t, store, broker, "Mac 1", "project-1")
	_ = pairedCatalogDevice(t, store, broker, "Mac 2", "project-2")
	server := &Server{store: store, broker: broker}

	response := httptest.NewRecorder()
	server.handleCodexProjectTasks(response, httptest.NewRequest(http.MethodGet, "/", nil), deviceOne, "project-2")
	if response.Code != http.StatusNotFound {
		t.Fatalf("cross-device project status = %d, body=%s", response.Code, response.Body.String())
	}

	broker.mu.Lock()
	broker.connections[deviceOne] = &runtimeConnection{}
	broker.mu.Unlock()
	request := httptest.NewRequest(http.MethodPost, "/", bytes.NewBufferString(`{
		"name":"Daily","kind":"cron","prompt":"Check","rrule":"FREQ=DAILY","status":"ACTIVE",
		"destination":"local","execution_environment":"local","project_id":"project-2"
	}`))
	response = httptest.NewRecorder()
	server.handleCodexAutomations(response, request, deviceOne, "")
	if response.Code != http.StatusNotFound {
		t.Fatalf("cross-device automation project status = %d, body=%s", response.Code, response.Body.String())
	}
	broker.mu.Lock()
	delete(broker.connections, deviceOne)
	broker.mu.Unlock()
}
