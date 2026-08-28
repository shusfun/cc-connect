package main

import (
	"bytes"
	"context"
	"flag"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/shusfun/cc-connect/config"
	"github.com/shusfun/cc-connect/core"
)

type stubMainAgent struct {
	workDir string
}

type stubAuthoritativeMainAgent struct {
	stubMainAgent
}

func (*stubAuthoritativeMainAgent) AuthoritativeSessionHistory() {}

func (a *stubMainAgent) Name() string { return "stub-main" }

func (a *stubMainAgent) StartSession(_ context.Context, _ string) (core.AgentSession, error) {
	return &stubMainAgentSession{}, nil
}

func (a *stubMainAgent) ListSessions(_ context.Context) ([]core.AgentSessionInfo, error) {
	return nil, nil
}

func (a *stubMainAgent) Stop() error { return nil }

func (a *stubMainAgent) SetWorkDir(dir string) {
	a.workDir = dir
}

func (a *stubMainAgent) GetWorkDir() string {
	return a.workDir
}

type stubMainAgentSession struct{}

func (s *stubMainAgentSession) Send(string, string, []core.ImageAttachment, []core.FileAttachment) error {
	return nil
}
func (s *stubMainAgentSession) RespondPermission(string, core.PermissionResult) error { return nil }
func (s *stubMainAgentSession) Events() <-chan core.Event                             { return nil }
func (s *stubMainAgentSession) Close() error                                          { return nil }
func (s *stubMainAgentSession) CurrentSessionID() string                              { return "" }
func (s *stubMainAgentSession) Alive() bool                                           { return true }

func TestFinalizeProjectPlatforms(t *testing.T) {
	t.Run("authoritative agent receives management platform", func(t *testing.T) {
		platforms, err := finalizeProjectPlatforms("codex-app", &stubAuthoritativeMainAgent{}, nil)
		if err != nil {
			t.Fatalf("finalizeProjectPlatforms() error = %v", err)
		}
		if len(platforms) != 1 || platforms[0].Name() != "web" {
			t.Fatalf("platforms = %#v, want management platform", platforms)
		}
	})

	t.Run("ordinary agent without platform is rejected", func(t *testing.T) {
		_, err := finalizeProjectPlatforms("demo", &stubMainAgent{}, nil)
		if err == nil || !strings.Contains(err.Error(), "does not support management sessions") {
			t.Fatalf("finalizeProjectPlatforms() error = %v", err)
		}
	})
}

func TestProjectStatePath(t *testing.T) {
	dataDir := t.TempDir()
	got := projectStatePath(dataDir, "my/project:one")
	want := filepath.Join(dataDir, "projects", "my_project_one.state.json")
	if got != want {
		t.Fatalf("projectStatePath() = %q, want %q", got, want)
	}
}

func TestResolveResetOnIdle(t *testing.T) {
	intPtr := func(v int) *int { return &v }

	cases := []struct {
		name          string
		configured    *int
		wantDuration  time.Duration
		wantDefaulted bool
	}{
		{
			name:          "unset applies default and reports defaulted",
			configured:    nil,
			wantDuration:  time.Duration(defaultResetOnIdleMins) * time.Minute,
			wantDefaulted: true,
		},
		{
			name:          "explicit zero opts out and is not defaulted",
			configured:    intPtr(0),
			wantDuration:  0,
			wantDefaulted: false,
		},
		{
			name:          "explicit positive value is honored",
			configured:    intPtr(45),
			wantDuration:  45 * time.Minute,
			wantDefaulted: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotDuration, gotDefaulted := resolveResetOnIdle(tc.configured)
			if gotDuration != tc.wantDuration {
				t.Errorf("duration = %v, want %v", gotDuration, tc.wantDuration)
			}
			if gotDefaulted != tc.wantDefaulted {
				t.Errorf("defaulted = %v, want %v", gotDefaulted, tc.wantDefaulted)
			}
		})
	}
}

func TestApplyProjectStateOverride(t *testing.T) {
	baseDir := t.TempDir()
	overrideDir := filepath.Join(t.TempDir(), "override")
	if err := os.Mkdir(overrideDir, 0o755); err != nil {
		t.Fatalf("mkdir override dir: %v", err)
	}

	store := core.NewProjectStateStore(filepath.Join(t.TempDir(), "projects", "demo.state.json"))
	store.SetWorkDirOverride(overrideDir)

	agent := &stubMainAgent{workDir: baseDir}
	got := applyProjectStateOverride("demo", agent, baseDir, store)

	if got != overrideDir {
		t.Fatalf("applyProjectStateOverride() = %q, want %q", got, overrideDir)
	}
	if agent.workDir != overrideDir {
		t.Fatalf("agent workDir = %q, want %q", agent.workDir, overrideDir)
	}
}

func TestBuildAgentOptionsInjectsProjectScope(t *testing.T) {
	proj := config.ProjectConfig{
		Name: "demo-project",
		Agent: config.AgentConfig{
			Options: map[string]any{
				"work_dir": "/tmp/work",
				"model":    "gpt-test",
			},
		},
	}

	got := buildAgentOptions("/tmp/data", proj)

	if got["cc_data_dir"] != "/tmp/data" {
		t.Fatalf("cc_data_dir = %v, want %q", got["cc_data_dir"], "/tmp/data")
	}
	if got["cc_project"] != "demo-project" {
		t.Fatalf("cc_project = %v, want %q", got["cc_project"], "demo-project")
	}
	if got["work_dir"] != "/tmp/work" || got["model"] != "gpt-test" {
		t.Fatalf("buildAgentOptions() lost existing options: %v", got)
	}
	if _, exists := proj.Agent.Options["cc_data_dir"]; exists {
		t.Fatalf("project agent options mutated: %v", proj.Agent.Options)
	}
}

func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stderr = w
	defer func() {
		os.Stderr = old
	}()

	fn()

	if err := w.Close(); err != nil {
		t.Fatalf("close writer: %v", err)
	}
	var buf bytes.Buffer
	if _, err := io.Copy(&buf, r); err != nil {
		t.Fatalf("copy stderr: %v", err)
	}
	if err := r.Close(); err != nil {
		t.Fatalf("close reader: %v", err)
	}
	return buf.String()
}

func TestPrintUsageOnlyListsCodexCompanionCommands(t *testing.T) {
	out := captureStderr(t, printUsage)

	if !strings.Contains(out, "Codex Desktop App remote companion") || !strings.Contains(out, "config-example") {
		t.Fatalf("printUsage() output missing Codex companion commands:\n%s", out)
	}
	for _, legacy := range []string{"Manage scheduled tasks", "Feishu/Lark", "Claude Code", "Cursor", "Weixin"} {
		if strings.Contains(out, legacy) {
			t.Fatalf("printUsage() output still contains legacy product entry %q:\n%s", legacy, out)
		}
	}
}

func TestValidateNoExtraTopLevelArgs(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		wantErr string
	}{
		{
			name: "no extra args",
			args: nil,
		},
		{
			name:    "unknown command",
			args:    []string{"bind", "--help"},
			wantErr: "unknown top-level command: bind",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateNoExtraTopLevelArgs(tt.args)
			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("validateNoExtraTopLevelArgs(%v) error = %v, want nil", tt.args, err)
				}
				return
			}
			if err == nil {
				t.Fatalf("validateNoExtraTopLevelArgs(%v) error = nil, want %q", tt.args, tt.wantErr)
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("validateNoExtraTopLevelArgs(%v) error = %q, want substring %q", tt.args, err.Error(), tt.wantErr)
			}
		})
	}
}

func TestValidateCodexProductConfig(t *testing.T) {
	base := func() *config.Config {
		return &config.Config{Projects: []config.ProjectConfig{{
			Name: "codex-runtime", Agent: config.AgentConfig{Type: "codexapp"},
			Platforms: []config.PlatformConfig{{Type: "feishu"}},
		}}}
	}
	if err := validateCodexProductConfig(base()); err != nil {
		t.Fatalf("valid Codex config rejected: %v", err)
	}

	tests := []struct {
		name    string
		mutate  func(*config.Config)
		wantErr string
	}{
		{name: "multiple internal projects", mutate: func(cfg *config.Config) { cfg.Projects = append(cfg.Projects, cfg.Projects[0]) }, wantErr: "只允许一个内部 Runtime 项目"},
		{name: "legacy agent", mutate: func(cfg *config.Config) { cfg.Projects[0].Agent.Type = "codex" }, wantErr: "只支持 agent.type"},
		{name: "lark", mutate: func(cfg *config.Config) { cfg.Projects[0].Platforms[0].Type = "lark" }, wantErr: "只支持飞书平台"},
		{name: "provider", mutate: func(cfg *config.Config) { cfg.Providers = []config.ProviderConfig{{Name: "legacy"}} }, wantErr: "不支持 Provider"},
		{name: "cron", mutate: func(cfg *config.Config) { value := true; cfg.Cron.Silent = &value }, wantErr: "不支持 [cron]"},
		{name: "bridge", mutate: func(cfg *config.Config) { value := false; cfg.Bridge.Enabled = &value }, wantErr: "不支持 [bridge]"},
		{name: "webhook", mutate: func(cfg *config.Config) { cfg.Webhook.Path = "/hook" }, wantErr: "不支持 [webhook]"},
		{name: "heartbeat", mutate: func(cfg *config.Config) { value := false; cfg.Projects[0].Heartbeat.Enabled = &value }, wantErr: "不支持 projects.heartbeat"},
		{name: "run as user", mutate: func(cfg *config.Config) { cfg.Projects[0].RunAsUser = "agent" }, wantErr: "不支持 run_as_user"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := base()
			test.mutate(cfg)
			err := validateCodexProductConfig(cfg)
			if err == nil || !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("validateCodexProductConfig() error = %v, want %q", err, test.wantErr)
			}
		})
	}
}

func TestParseRootCLIOptionsGlobalFlagsBeforeSubcommand(t *testing.T) {
	opts, err := parseRootCLIOptions([]string{"--config", "/tmp/test-config.toml", "--log-max-size", "12MB", "--log-max-backups", "7", "sessions", "list"})
	if err != nil {
		t.Fatalf("parseRootCLIOptions() error = %v", err)
	}
	if opts.configPath != "/tmp/test-config.toml" {
		t.Fatalf("configPath = %q, want %q", opts.configPath, "/tmp/test-config.toml")
	}
	if opts.logMaxSize != "12MB" {
		t.Fatalf("logMaxSize = %q, want %q", opts.logMaxSize, "12MB")
	}
	if opts.logMaxBackups != 7 {
		t.Fatalf("logMaxBackups = %d, want 7", opts.logMaxBackups)
	}
	if opts.showVersion {
		t.Fatal("showVersion = true, want false")
	}
	wantArgs := []string{"sessions", "list"}
	if !reflect.DeepEqual(opts.args, wantArgs) {
		t.Fatalf("args = %v, want %v", opts.args, wantArgs)
	}
}

func TestTopLevelCommandHandlersOnlyExposeConfigExample(t *testing.T) {
	if len(topLevelCommandHandlers) != 1 || topLevelCommandHandlers["config-example"] == nil {
		t.Fatalf("topLevelCommandHandlers = %v, want only config-example", topLevelCommandHandlers)
	}
	for _, command := range []string{"timer", "at", "cron", "sessions", "provider", "feishu", "weixin"} {
		if topLevelCommandHandlers[command] != nil {
			t.Fatalf("legacy top-level command %q is still registered", command)
		}
	}
}

func TestCodexRequiredDisabledCommands(t *testing.T) {
	got := make(map[string]bool, len(codexRequiredDisabledCommands))
	for _, command := range codexRequiredDisabledCommands {
		got[command] = true
	}
	for _, command := range []string{"provider", "cron", "timer", "heartbeat", "bind"} {
		if !got[command] {
			t.Errorf("Codex production command restrictions missing %q", command)
		}
	}
}

func TestParseRootCLIOptionsPreservesSubcommandHelp(t *testing.T) {
	opts, err := parseRootCLIOptions([]string{"--config", "/tmp/test-config.toml", "send", "--help"})
	if err != nil {
		t.Fatalf("parseRootCLIOptions() error = %v", err)
	}
	wantArgs := []string{"send", "--help"}
	if !reflect.DeepEqual(opts.args, wantArgs) {
		t.Fatalf("args = %v, want %v", opts.args, wantArgs)
	}
}

func TestParseRootCLIOptionsHelp(t *testing.T) {
	_, err := parseRootCLIOptions([]string{"--help"})
	if err == nil {
		t.Fatal("parseRootCLIOptions(--help) error = nil, want flag.ErrHelp")
	}
	if !strings.Contains(err.Error(), flag.ErrHelp.Error()) {
		t.Fatalf("parseRootCLIOptions(--help) error = %q, want %q", err.Error(), flag.ErrHelp.Error())
	}
}

func TestRunTopLevelCommandUnknown(t *testing.T) {
	if runTopLevelCommand([]string{"bind", "--help"}) {
		t.Fatal("runTopLevelCommand() handled unknown command")
	}
}
