package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"time"
)

// ManagementServer 只承载 Control 消费的私有运行状态传输。
type ManagementServer struct {
	server *http.Server

	mu      sync.RWMutex
	engines map[string]*Engine
}

func NewManagementServer() *ManagementServer {
	return &ManagementServer{engines: make(map[string]*Engine)}
}

func (m *ManagementServer) RegisterEngine(name string, engine *Engine) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.engines[name] = engine
}

func (m *ManagementServer) ServeControl(listener net.Listener) error {
	if listener == nil {
		return fmt.Errorf("private control listener is required")
	}
	m.server = &http.Server{Handler: m.controlHandler(), ReadHeaderTimeout: 10 * time.Second}
	if err := m.server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("private control server: %w", err)
	}
	return nil
}

func (m *ManagementServer) controlHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/internal/v1/control/runtime-activity", m.handleRuntimeActivity)
	return mux
}

func (m *ManagementServer) handleRuntimeActivity(w http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeManagementError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	active := 0
	m.mu.RLock()
	for _, engine := range m.engines {
		active += len(engine.ActiveSessionKeys())
	}
	m.mu.RUnlock()
	writeManagementJSON(w, http.StatusOK, map[string]int{
		"active_turns":         active,
		"pending_interactions": 0,
		"realtime_sessions":    0,
	})
}

func (m *ManagementServer) Stop() {
	if m.server != nil {
		_ = m.server.Close()
	}
}

func writeManagementJSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(map[string]any{"ok": true, "data": data}); err != nil {
		slog.Error("private control server: write JSON failed", "error", err)
	}
}

func writeManagementError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": message}); err != nil {
		slog.Error("private control server: write error JSON failed", "error", err)
	}
}
