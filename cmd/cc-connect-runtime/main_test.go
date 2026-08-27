package main

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/chenhg5/cc-connect/core"
)

type runtimeValidationAgent struct {
	core.Agent
	projects   []core.AgentProjectInfo
	projectErr error
	sessionErr error
}

func (a runtimeValidationAgent) ListProjects(context.Context) ([]core.AgentProjectInfo, error) {
	return a.projects, a.projectErr
}

func (a runtimeValidationAgent) ListSessions(context.Context) ([]core.AgentSessionInfo, error) {
	return nil, a.sessionErr
}

func TestValidateCodexRuntimeRequiresDesktopAppProjectsAndTasks(t *testing.T) {
	t.Run("valid", func(t *testing.T) {
		err := validateCodexRuntime(context.Background(), runtimeValidationAgent{projects: []core.AgentProjectInfo{{ID: "project-1", Name: "项目"}}})
		if err != nil {
			t.Fatalf("validateCodexRuntime() = %v", err)
		}
	})

	t.Run("no projects", func(t *testing.T) {
		err := validateCodexRuntime(context.Background(), runtimeValidationAgent{})
		if err == nil || !strings.Contains(err.Error(), "没有可用项目") {
			t.Fatalf("validateCodexRuntime() error = %v", err)
		}
	})

	t.Run("task catalog unavailable", func(t *testing.T) {
		err := validateCodexRuntime(context.Background(), runtimeValidationAgent{projects: []core.AgentProjectInfo{{ID: "project-1", Name: "项目"}}, sessionErr: errors.New("offline")})
		if err == nil || !strings.Contains(err.Error(), "无法读取 Codex App 任务状态") {
			t.Fatalf("validateCodexRuntime() error = %v", err)
		}
	})
}

func TestRunRequiresInteractiveCodexAppTerminal(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CODEX_APP_TOOLS_PIPE_PATH", "")
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("CC_CONNECT_CODEXAPP_BRIDGE_FD", "")
	err := run(nil)
	if err == nil || !strings.Contains(err.Error(), "interactive Codex App terminal") {
		t.Fatalf("run() error = %v", err)
	}
	if _, statErr := os.Stat(defaultStateDirectory()); statErr != nil && !os.IsNotExist(statErr) {
		t.Fatalf("inspect Runtime state: %v", statErr)
	}
}

var _ core.AgentProjectCatalog = runtimeValidationAgent{}
