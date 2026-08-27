package codexapp

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/chenhg5/cc-connect/core"
)

func TestInheritedBridgeFDValidation(t *testing.T) {
	t.Setenv(bridgeWorkerFDEnv, "")
	if fd, err := InheritedBridgeFD(); err != nil || fd != 0 {
		t.Fatalf("InheritedBridgeFD() = %d, %v", fd, err)
	}

	t.Setenv(bridgeWorkerFDEnv, "3")
	if fd, err := InheritedBridgeFD(); err != nil || fd != 3 {
		t.Fatalf("InheritedBridgeFD() = %d, %v", fd, err)
	}

	for _, invalid := range []string{"not-a-number", "2", "-1"} {
		t.Run(invalid, func(t *testing.T) {
			t.Setenv(bridgeWorkerFDEnv, invalid)
			if _, err := InheritedBridgeFD(); err == nil || !strings.Contains(err.Error(), "invalid inherited relay fd") {
				t.Fatalf("InheritedBridgeFD() error = %v", err)
			}
		})
	}
}

func TestBootstrapRuntimeRequiresInteractiveCodexAppTerminal(t *testing.T) {
	err := BootstrapRuntime("/tmp/not-inspected.sock", "", nil)
	if err == nil || !strings.Contains(err.Error(), "interactive Codex App terminal") {
		t.Fatalf("BootstrapRuntime() error = %v", err)
	}
}

func TestInheritedRelayDoesNotScanDesktopSockets(t *testing.T) {
	candidatesCalled := false
	bridge, err := NewBridge(BridgeOptions{
		ContextThreadID: "context-task",
		InheritedFD:     3,
		candidates: func() ([]string, error) {
			candidatesCalled = true
			return nil, nil
		},
		newClient: func(path string) (bridgeRPCClient, error) {
			if path != "inherited App relay" {
				t.Fatalf("client path = %q", path)
			}
			return healthyScriptedClient(), nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = bridge.Close() }()
	if candidatesCalled {
		t.Fatal("worker using inherited relay scanned Desktop sockets")
	}
}

func TestDesktopTaskFlowNeverExecutesCodexFromPATH(t *testing.T) {
	temporaryDirectory := t.TempDir()
	markerPath := filepath.Join(temporaryDirectory, "codex-executed")
	fakeCodex := filepath.Join(temporaryDirectory, "codex")
	if err := os.WriteFile(fakeCodex, []byte("#!/bin/sh\ntouch \""+markerPath+"\"\nexit 97\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", temporaryDirectory+string(os.PathListSeparator)+os.Getenv("PATH"))

	client := &scriptedBridgeClient{requestFunc: func(_ context.Context, method string, params any, _ string) (json.RawMessage, error) {
		if method == "tools/list" {
			return toolsListResult(), nil
		}
		values, _ := params.(map[string]any)
		if values["tool"] == "create_thread" {
			return toolResult(`{"threadId":"created-by-app","hostId":"local"}`), nil
		}
		return toolResult(`{"projects":[{"projectId":"project-1","projectKind":"local","label":"项目","path":"/repo","hostId":"local","isGitRepository":true}]}`), nil
	}}
	bridge, err := NewBridge(bridgeOptions(func(string) (bridgeRPCClient, error) { return client, nil }, "app.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = bridge.Close() }()
	agent := newAgentWithCaller(bridge)
	created, err := agent.CreateSession(t.Context(), core.AgentSessionCreateRequest{ProjectID: "project-1", Prompt: "第一条消息"})
	if err != nil {
		t.Fatal(err)
	}
	if created.ID != "created-by-app" {
		t.Fatalf("created task = %q", created.ID)
	}
	if _, err := os.Stat(markerPath); !os.IsNotExist(err) {
		t.Fatalf("PATH codex executable was invoked: %v", err)
	}
}
