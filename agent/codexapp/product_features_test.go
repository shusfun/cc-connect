package codexapp

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/shusfun/cc-connect/core"
)

func writeAutomationFixture(t *testing.T, home, id, name string) {
	t.Helper()
	directory := filepath.Join(home, "automations", id)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	raw := `id = "` + id + `"
name = "` + name + `"
kind = "cron"
prompt = "检查项目"
rrule = "FREQ=DAILY;BYHOUR=9"
status = "ACTIVE"
destination = "worktree"
execution_environment = "worktree"
project_id = "project-1"
model = "gpt-5.6-sol"
reasoning_effort = "high"
`
	if err := os.WriteFile(filepath.Join(directory, "automation.toml"), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestAutomationUsesStructuredFilesAndAppMutationTool(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CODEX_HOME", home)
	writeAutomationFixture(t, home, "daily-check", "每日检查")
	caller := &fakeCaller{tools: map[string]bool{"automation_update": true}, responses: map[string][]json.RawMessage{
		"automation_update": {toolResult(`{"ok":true}`)},
	}}
	agent := newAgentWithCaller(caller)
	items, err := agent.ListAutomations(context.Background())
	if err != nil || len(items) != 1 || items[0].ID != "daily-check" || items[0].ProjectID != "project-1" {
		t.Fatalf("ListAutomations() = %#v, %v", items, err)
	}
	created, err := agent.CreateAutomation(context.Background(), core.AgentAutomationMutation{
		Name: "每日检查", Kind: "cron", Prompt: "检查项目", RRule: "FREQ=DAILY;BYHOUR=9", Status: "ACTIVE",
		Destination: "local", ExecutionEnvironment: "local", ProjectID: "project-1",
	})
	if err != nil || created.ID != "daily-check" {
		t.Fatalf("CreateAutomation() = %#v, %v", created, err)
	}
	caller.mu.Lock()
	defer caller.mu.Unlock()
	if len(caller.calls) != 1 || caller.calls[0].tool != "automation_update" {
		t.Fatalf("calls = %#v", caller.calls)
	}
	arguments, ok := caller.calls[0].arguments.(map[string]any)
	if !ok || arguments["mode"] != "create" || arguments["projectId"] != "project-1" || arguments["executionEnvironment"] != "local" {
		t.Fatalf("automation arguments = %#v", caller.calls[0].arguments)
	}
}

func TestAutomationRejectsIncompleteOwnerAppTargets(t *testing.T) {
	tests := []struct {
		name     string
		mutation core.AgentAutomationMutation
	}{
		{name: "heartbeat without target", mutation: core.AgentAutomationMutation{
			Name: "跟进", Kind: "heartbeat", Prompt: "继续处理", RRule: "FREQ=HOURLY", Status: "ACTIVE", Destination: "thread",
		}},
		{name: "cron with worktree fallback", mutation: core.AgentAutomationMutation{
			Name: "检查", Kind: "cron", Prompt: "检查状态", RRule: "FREQ=DAILY", Status: "ACTIVE",
			Destination: "worktree", ExecutionEnvironment: "worktree",
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := validateAutomationMutation(test.mutation, false); err == nil {
				t.Fatal("incomplete automation target was accepted")
			}
		})
	}
}

func TestPluginCommandsUseStructuredOfficialCLIAndRedactErrors(t *testing.T) {
	directory := t.TempDir()
	marker := filepath.Join(directory, "installed")
	script := `#!/bin/sh
set -eu
if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
  if [ -f "` + marker + `" ]; then
    printf '%s\n' '{"installed":[{"pluginId":"demo@official","name":"Demo","marketplaceName":"Official","version":"1","installed":true,"enabled":true,"source":{},"marketplaceSource":{},"installPolicy":"allowed","authPolicy":"none"}],"available":[]}'
  else
    printf '%s\n' '{"installed":[],"available":[{"pluginId":"demo@official","name":"Demo","marketplaceName":"Official","version":"1","installed":false,"enabled":false,"source":{},"marketplaceSource":{},"installPolicy":"allowed","authPolicy":"none"}]}'
  fi
elif [ "$1" = "plugin" ] && [ "$2" = "add" ]; then
  : > "` + marker + `"
  printf '%s\n' '{}'
elif [ "$1" = "plugin" ] && [ "$2" = "remove" ]; then
  /bin/rm -f "` + marker + `"
  printf '%s\n' '{}'
else
  printf '%s\n' 'token=private-value' >&2
  exit 9
fi
`
	path := filepath.Join(directory, "codex")
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	agent := &Agent{}
	plugins, err := agent.ListPlugins(context.Background(), true)
	if err != nil || len(plugins) != 1 || plugins[0].ID != "demo@official" || plugins[0].Installed {
		t.Fatalf("ListPlugins() = %#v, %v", plugins, err)
	}
	installed, err := agent.InstallPlugin(context.Background(), "demo@official")
	if err != nil || !installed.Installed {
		t.Fatalf("InstallPlugin() = %#v, %v", installed, err)
	}
	if err := agent.RemovePlugin(context.Background(), "demo@official"); err != nil {
		t.Fatal(err)
	}
	if _, err := agent.InstallPlugin(context.Background(), "bad plugin"); err == nil {
		t.Fatal("invalid plugin id was accepted")
	}
	if got := redactPluginError("Authorization: Bearer-private token=private-value password:guess"); strings.Contains(got, "private") || strings.Contains(got, "guess") {
		t.Fatalf("redacted error leaked secret: %q", got)
	}
}
