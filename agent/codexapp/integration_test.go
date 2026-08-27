package codexapp

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestDesktopAppReadOnlyIntegration(t *testing.T) {
	if os.Getenv("CC_CODEXAPP_INTEGRATION") != "1" {
		t.Skip("set CC_CODEXAPP_INTEGRATION=1 to inspect the running Desktop App")
	}
	taskID := os.Getenv("CODEX_THREAD_ID")
	if taskID == "" {
		t.Fatal("CODEX_THREAD_ID is required")
	}
	bridgeFD, err := InheritedBridgeFD()
	if err != nil {
		t.Fatal(err)
	}
	if bridgeFD == 0 {
		socketPath := os.Getenv("CODEX_APP_TOOLS_PIPE_PATH")
		if socketPath == "" {
			t.Fatal("CODEX_APP_TOOLS_PIPE_PATH is required")
		}
		if err := BootstrapRuntime(socketPath, "", os.Args[1:]); err != nil {
			t.Fatal(err)
		}
		return
	}
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	bridge, err := NewBridge(BridgeOptions{ContextThreadID: taskID, InheritedFD: bridgeFD})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = bridge.Close() }()
	agent := newAgentWithCaller(bridge)
	projects, err := agent.ListProjects(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(projects) == 0 {
		t.Fatal("Desktop App returned no projects")
	}
	sessions, err := agent.ListSessions(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(sessions) == 0 {
		t.Fatal("Desktop App returned no tasks")
	}
	snapshot, err := agent.ReadSession(ctx, taskID, "", "", 2)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Session.ID != taskID {
		t.Fatalf("snapshot task = %q, want %q", snapshot.Session.ID, taskID)
	}
}
