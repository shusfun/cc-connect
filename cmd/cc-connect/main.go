package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	ccconnect "github.com/shusfun/cc-connect"
	"github.com/shusfun/cc-connect/config"
	"github.com/shusfun/cc-connect/core"
	"github.com/shusfun/cc-connect/daemon"
	"github.com/shusfun/cc-connect/remotenative"
	// Agent and platform imports are in separate plugin_*.go files
	// controlled by build tags. See Makefile for selective compilation.
)

var (
	version   = "dev"
	commit    = "none"
	buildTime = "unknown"
)

// globalAPIServer holds the running API server so the config-reload path can
// re-apply hot-reloadable settings (e.g. max attachment size) without threading
// it through the engine's reload closure. nil when the API server is disabled.
var globalAPIServer *core.APIServer

// defaultResetOnIdleMins is applied when a project does not set
// reset_on_idle_mins. After this many minutes of user inactivity, cc-connect
// rotates to a fresh session for the next message instead of resuming the
// previous transcript via --continue. This avoids "context drift" where stale
// chat history (failed commands, debugging noise, abandoned tangents) is
// repeatedly re-ingested and starts to dominate the model's attention. The
// previous session is preserved and remains accessible via /list and /switch.
//
// Set reset_on_idle_mins = 0 in config.toml to opt out and restore the
// previous behavior of always continuing the prior session.
const defaultResetOnIdleMins = 0

// resolveResetOnIdle returns the configured reset-on-idle duration for a
// project, applying defaultResetOnIdleMins when the field is unset. The second
// return value indicates whether the default was applied, so the caller can
// emit a one-time nudge log directing users to the docs.
func resolveResetOnIdle(configured *int) (time.Duration, bool) {
	if configured != nil {
		return time.Duration(*configured) * time.Minute, false
	}
	return time.Duration(defaultResetOnIdleMins) * time.Minute, true
}

// logSizeSource describes where the resolved log size came from, so the
// caller can log it and operators can audit the active setting without
// grepping systemd/launchd definitions.
type logSizeSource string

const (
	logSizeSourceFlag    logSizeSource = "flag"
	logSizeSourceEnv     logSizeSource = "env"
	logSizeSourceDefault logSizeSource = "default"
)

// resolveLogMaxSize picks the effective max log size in bytes, applying the
// priority order: explicit flag value > CC_LOG_MAX_SIZE env var > built-in
// default. flagValue is the raw string from --log-max-size ("" if not set).
// Returns the byte count and which source won. Invalid flag/env values are
// logged to stderr and the value is ignored — a malformed setting must never
// silently downgrade to "0 bytes" or another surprise.
func resolveLogMaxSize(flagValue string) (int64, logSizeSource) {
	if strings.TrimSpace(flagValue) != "" {
		n, err := daemon.ParseLogSize(flagValue)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: ignoring --log-max-size=%q: %v\n", flagValue, err)
		} else {
			return n, logSizeSourceFlag
		}
	}
	if v := os.Getenv("CC_LOG_MAX_SIZE"); v != "" {
		n, err := daemon.ParseLogSize(v)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: ignoring CC_LOG_MAX_SIZE=%q: %v\n", v, err)
		} else {
			return n, logSizeSourceEnv
		}
	}
	return int64(daemon.DefaultLogMaxSize), logSizeSourceDefault
}

// preScanLogMaxSizeFlag returns the value passed via --log-max-size before
// flag.Parse() runs, so the rotating-writer setup can honour the flag too.
// Returns "" if the flag is absent. Both "--log-max-size VALUE" and
// "--log-max-size=VALUE" forms are recognised.
func preScanLogMaxSizeFlag(args []string) string {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--log-max-size" {
			if i+1 < len(args) {
				return args[i+1]
			}
			return ""
		}
		if strings.HasPrefix(a, "--log-max-size=") {
			return strings.TrimPrefix(a, "--log-max-size=")
		}
	}
	return ""
}

// logBackupsSource describes where the resolved max-backups count came
// from, mirroring logSizeSource so operators can audit the active value
// from the startup log line alone.
type logBackupsSource string

const (
	logBackupsSourceFlag    logBackupsSource = "flag"
	logBackupsSourceEnv     logBackupsSource = "env"
	logBackupsSourceDefault logBackupsSource = "default"
)

// resolveLogMaxBackups picks the effective number of rotated log backups
// to retain, with the same priority order as resolveLogMaxSize: explicit
// flag value > CC_LOG_MAX_BACKUPS env var > built-in default. Returns
// the count and which source won. Invalid inputs are logged to stderr
// and the value is ignored so a typo never silently downgrades to "0".
func resolveLogMaxBackups(flagValue string) (int, logBackupsSource) {
	if strings.TrimSpace(flagValue) != "" {
		n, err := daemon.ParseLogBackups(flagValue)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: ignoring --log-max-backups=%q: %v\n", flagValue, err)
		} else {
			return n, logBackupsSourceFlag
		}
	}
	if v := os.Getenv("CC_LOG_MAX_BACKUPS"); v != "" {
		n, err := daemon.ParseLogBackups(v)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: ignoring CC_LOG_MAX_BACKUPS=%q: %v\n", v, err)
		} else {
			return n, logBackupsSourceEnv
		}
	}
	return daemon.DefaultLogMaxBackups, logBackupsSourceDefault
}

// preScanLogMaxBackupsFlag returns the value passed via --log-max-backups
// before flag.Parse() runs, mirroring preScanLogMaxSizeFlag. Returns ""
// if the flag is absent.
func preScanLogMaxBackupsFlag(args []string) string {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--log-max-backups" {
			if i+1 < len(args) {
				return args[i+1]
			}
			return ""
		}
		if strings.HasPrefix(a, "--log-max-backups=") {
			return strings.TrimPrefix(a, "--log-max-backups=")
		}
	}
	return ""
}

// resolveMaxAttachmentSize returns the per-attachment size limit in bytes for
// the /send API. Priority: CC_MAX_ATTACHMENT_SIZE_MB env var (MiB) >
// config max_attachment_size_mb > core.DefaultMaxAttachmentSize. The env var
// intentionally uses the same MiB unit as the config field so the two knobs
// cannot silently disagree by a factor of 1<<20. A malformed or non-positive
// env value is ignored (falling through to config/default) rather than being
// fatal — the same lenient posture as resolveLogMaxSize, which also warns so
// a typo never silently downgrades the setting.
func resolveMaxAttachmentSize(cfg *config.Config) int64 {
	if v := strings.TrimSpace(os.Getenv("CC_MAX_ATTACHMENT_SIZE_MB")); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			return n << 20
		}
		fmt.Fprintf(os.Stderr, "warning: ignoring CC_MAX_ATTACHMENT_SIZE_MB=%q: must be a positive integer (MiB)\n", v)
	}
	if cfg != nil && cfg.MaxAttachmentSizeMB > 0 {
		return int64(cfg.MaxAttachmentSizeMB) << 20
	}
	return core.DefaultMaxAttachmentSize
}

var topLevelCommandHandlers = map[string]func([]string){
	"config-example": func(_ []string) {
		fmt.Print(ccconnect.ConfigExampleTOML)
	},
}

var codexRequiredDisabledCommands = []string{
	"provider",
	"cron",
	"timer",
	"heartbeat",
	"bind",
}

func main() {
	// When started as a daemon (CC_LOG_FILE set), redirect logs to a rotating file.
	// Log file setup happens before flag.Parse() so the rotating writer is in
	// place before any slog output. To still honour --log-max-size, we
	// pre-scan os.Args here for the flag value; this is a small, deliberate
	// duplication of flag parsing for one well-known key.
	var logWriter io.Writer
	var logCloser io.Closer
	if logFile := os.Getenv("CC_LOG_FILE"); logFile != "" {
		maxSize, maxSizeSrc := resolveLogMaxSize(preScanLogMaxSizeFlag(os.Args[1:]))
		maxBackups, maxBackupsSrc := resolveLogMaxBackups(preScanLogMaxBackupsFlag(os.Args[1:]))
		fmt.Fprintf(os.Stderr, "log: redirecting to %s with max_size=%d bytes (source: %s), max_backups=%d (source: %s)\n", logFile, maxSize, maxSizeSrc, maxBackups, maxBackupsSrc)
		w, err := daemon.NewRotatingWriter(logFile, maxSize, maxBackups)
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to open log file %s: %v\n", logFile, err)
			os.Exit(1)
		}
		logWriter = w
		logCloser = w
		slog.SetDefault(slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{Level: slog.LevelInfo})))
	}

	rootOpts, err := parseRootCLIOptions(os.Args[1:])
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		os.Exit(2)
	}

	// Cross-check: the rotating-writer setup above consumed a pre-scanned
	// value of --log-max-size. Validate the parsed value too so malformed
	// values surface a clear warning.
	if strings.TrimSpace(rootOpts.logMaxSize) != "" {
		if _, err := daemon.ParseLogSize(rootOpts.logMaxSize); err != nil {
			fmt.Fprintf(os.Stderr, "warning: --log-max-size=%q: %v\n", rootOpts.logMaxSize, err)
		}
	}
	if rootOpts.logMaxBackups < 0 {
		fmt.Fprintf(os.Stderr, "warning: --log-max-backups=%d must be >= 0 (0 means use env/default)\n", rootOpts.logMaxBackups)
	}

	if rootOpts.showVersion {
		fmt.Printf("cc-connect %s\ncommit:  %s\nbuilt:   %s\n", version, commit, buildTime)
		return
	}

	if runTopLevelCommand(rootOpts.args) {
		return
	}

	if err := validateNoExtraTopLevelArgs(rootOpts.args); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n\n", err)
		printUsage()
		os.Exit(1)
	}

	core.VersionInfo = fmt.Sprintf("cc-connect %s\ncommit: %s\nbuilt: %s", version, commit, buildTime)
	core.CurrentVersion = version
	core.CurrentCommit = commit
	core.CurrentBuildTime = buildTime

	configPath := resolveConfigPath(rootOpts.configPath)

	// Handle --force: kill any existing instance before we try to acquire the lock
	if rootOpts.force {
		if KillExistingInstance(configPath) {
			slog.Info("killed existing instance via --force")
		}
	}

	// Acquire instance lock to prevent duplicate processes
	instanceLock, err := AcquireInstanceLock(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		fmt.Fprintf(os.Stderr, "Use --force to kill the existing instance.\n")
		os.Exit(1)
	}
	slog.Info("acquired instance lock", "path", instanceLock.Path())

	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		if err := bootstrapConfig(configPath); err != nil {
			fmt.Fprintf(os.Stderr, "Error creating config: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Created default config at %s\n", configPath)
		fmt.Println("Please edit this file to add your agent and platform credentials, then run cc-connect again.")
		os.Exit(0)
	}

	cfg, err := config.Load(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading config (%s): %v\n", configPath, err)
		os.Exit(1)
	}
	if err := validateCodexProductConfig(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "Error loading config (%s): %v\n", configPath, err)
		os.Exit(1)
	}

	config.ConfigPath = configPath
	slog.Info("config loaded", "path", configPath)

	runtimeSocket := strings.TrimSpace(rootOpts.runtimeSocket)
	if runtimeSocket == "" {
		runtimeSocket = strings.TrimSpace(os.Getenv("CC_RUNTIME_SOCKET"))
	}
	if len(cfg.Projects) == 0 {
		fmt.Fprintf(os.Stderr, "Error: no projects configured in %s\n", configPath)
		fmt.Fprintln(os.Stderr, "Add at least one [[project]] section to your config.toml, or run:")
		fmt.Fprintln(os.Stderr, "  cc-connect init")
		os.Exit(1)
	}

	setupLogger(cfg.Log.Level, logWriter)

	engines := make([]*core.Engine, 0, len(cfg.Projects))

	for _, proj := range cfg.Projects {
		// Inject project-level run_as_user / run_as_env into the agent's
		// opts map so agents that support isolation can pick them up
		// without needing their own top-level config plumbing.
		if proj.RunAsUser != "" {
			if proj.Agent.Options == nil {
				proj.Agent.Options = map[string]any{}
			}
			proj.Agent.Options["run_as_user"] = proj.RunAsUser
			if len(proj.RunAsEnv) > 0 {
				proj.Agent.Options["run_as_env"] = proj.RunAsEnv
			}
		}
		var agent core.Agent
		var err error
		if strings.EqualFold(proj.Agent.Type, "codexapp") && runtimeSocket != "" {
			agent, err = remotenative.New(runtimeSocket)
		} else {
			agent, err = core.CreateAgent(proj.Agent.Type, buildAgentOptions(cfg.DataDir, proj))
		}
		if err != nil {
			slog.Error("failed to create agent", "project", proj.Name, "error", err)
			os.Exit(1)
		}

		var platforms []core.Platform
		for _, pc := range proj.Platforms {
			opts := make(map[string]any, len(pc.Options)+2)
			for k, v := range pc.Options {
				opts[k] = v
			}
			opts["cc_data_dir"] = cfg.DataDir
			opts["cc_project"] = proj.Name
			p, err := core.CreatePlatform(pc.Type, opts)
			if err != nil {
				slog.Error("failed to create platform", "project", proj.Name, "type", pc.Type, "error", err)
				os.Exit(1)
			}
			platforms = append(platforms, p)
		}
		platforms, err = finalizeProjectPlatforms(proj.Name, agent, platforms)
		if err != nil {
			slog.Error("project has no available platform", "project", proj.Name, "error", err)
			_ = agent.Stop()
			os.Exit(1)
		}

		workDir, _ := proj.Agent.Options["work_dir"].(string)
		projectState := core.NewProjectStateStore(projectStatePath(cfg.DataDir, proj.Name))
		effectiveWorkDir := applyProjectStateOverride(proj.Name, agent, workDir, projectState)
		sessionFile := sessionStorePath(cfg.DataDir, proj.Name, effectiveWorkDir)

		// Parse language setting
		var lang core.Language
		switch cfg.Language {
		case "zh", "chinese":
			lang = core.LangChinese
		case "zh-TW", "zh_TW", "zhtw":
			lang = core.LangTraditionalChinese
		case "ja", "japanese":
			lang = core.LangJapanese
		case "es", "spanish":
			lang = core.LangSpanish
		case "en", "english":
			lang = core.LangEnglish
		default:
			lang = core.LangAuto // auto-detect
		}

		engine := core.NewEngine(proj.Name, agent, platforms, sessionFile, lang)
		engine.SetRequiredDisabledCommands(codexRequiredDisabledCommands)
		// Wire display settings including show_context_indicator and reply_footer
		// Global [display] config can be overridden by project-level settings
		_, _, _, _, _, showCtx, showFooter, _ := config.EffectiveDisplay(cfg, &proj)
		engine.SetShowContextIndicator(showCtx)
		showWorkdir := true
		if proj.ShowWorkdirIndicator != nil {
			showWorkdir = *proj.ShowWorkdirIndicator
		}
		engine.SetShowWorkdirIndicator(showWorkdir)
		engine.SetReplyFooterEnabled(showFooter)
		engine.SetAttachmentSendEnabled(cfg.AttachmentSend != "off")
		engine.SetFilterExternalSessions(proj.FilterExternalSessions != nil && *proj.FilterExternalSessions)
		engine.SetBaseWorkDir(workDir)
		engine.SetProjectStateStore(projectState)
		engine.SetDataDir(cfg.DataDir)

		// Wire multi-workspace mode
		if proj.Mode == "multi-workspace" {
			baseDir := proj.BaseDir
			if strings.HasPrefix(baseDir, "~/") {
				home, _ := os.UserHomeDir()
				baseDir = filepath.Join(home, baseDir[2:])
			}
			if err := os.MkdirAll(baseDir, 0o755); err != nil {
				slog.Error("failed to create base_dir", "path", baseDir, "err", err)
				continue
			}
			bindingStore := filepath.Join(cfg.DataDir, "workspace_bindings.json")
			engine.SetMultiWorkspace(baseDir, bindingStore)
			if proj.WorkspaceInitAllowLocalPaths != nil {
				engine.SetWorkspaceInitAllowLocalPaths(*proj.WorkspaceInitAllowLocalPaths)
			}
			idleMins := cfg.WorkspaceIdleTimeoutMins
			if idleMins == nil && proj.WorkspaceIdleTimeoutMinsLegacy != nil {
				slog.Warn("workspace_idle_timeout_mins under [[projects]] is deprecated; move it to the top level of config.toml. Honoring the legacy value for backwards compatibility.",
					"project", proj.Name, "value", *proj.WorkspaceIdleTimeoutMinsLegacy)
				idleMins = proj.WorkspaceIdleTimeoutMinsLegacy
			}
			if idleMins != nil {
				mins := *idleMins
				if mins <= 0 {
					engine.SetWorkspaceIdleTimeout(0)
				} else {
					engine.SetWorkspaceIdleTimeout(time.Duration(mins) * time.Minute)
				}
			}
			if proj.SkipGit != nil {
				engine.SetSkipGit(*proj.SkipGit)
			}
			slog.Info("multi-workspace mode enabled", "project", proj.Name, "base_dir", baseDir)
		}

		// Wire global custom commands
		for _, c := range cfg.Commands {
			engine.AddCommand(c.Name, c.Description, c.Prompt, c.Exec, c.WorkDir, "config")
		}

		// Wire command persistence callbacks
		engine.SetCommandSaveAddFunc(func(name, description, prompt, exec, workDir string) error {
			return config.AddCommand(config.CommandConfig{Name: name, Description: description, Prompt: prompt, Exec: exec, WorkDir: workDir})
		})
		engine.SetCommandSaveDelFunc(func(name string) error {
			return config.RemoveCommand(name)
		})

		// Wire global aliases
		for _, a := range cfg.Aliases {
			engine.AddAlias(a.Name, a.Command)
		}
		engine.SetAliasSaveAddFunc(func(name, command string) error {
			return config.AddAlias(config.AliasConfig{Name: name, Command: command})
		})
		engine.SetAliasSaveDelFunc(func(name string) error {
			return config.RemoveAlias(name)
		})

		// Wire banned words
		if len(cfg.BannedWords) > 0 {
			engine.SetBannedWords(cfg.BannedWords)
		}

		// Wire disabled commands (project-level)
		if len(proj.DisabledCommands) > 0 {
			engine.SetDisabledCommands(proj.DisabledCommands)
		}

		// Wire admin allowlist for privileged commands
		engine.SetAdminFrom(proj.AdminFrom)

		// Wire per-user role-based policies
		if proj.Users != nil {
			engine.SetUserRoles(buildUserRoleManager(proj.Users))
		}

		// Wire display truncation settings (includes legacy quiet → display mapping)
		{
			mode, tm, tool, tmlen, toollen, _, _, hideAgentFooter := config.EffectiveDisplay(cfg, &proj)
			historyMaxLen := config.EffectiveHistoryMaxLen(cfg, &proj)
			engine.SetDisplayConfig(core.DisplayCfg{
				Mode:             mode,
				CardMode:         config.EffectiveCardMode(cfg, &proj),
				ThinkingMessages: tm,
				ThinkingMaxLen:   tmlen,
				ToolMaxLen:       toollen,
				ToolMessages:     tool,
				HistoryMaxLen:    &historyMaxLen,
				HideAgentFooter:  hideAgentFooter,
			})
		}

		// Wire shell configuration
		shell, shellFlag, shellProfile := config.EffectiveShell(cfg, &proj)
		engine.SetShell(shell, shellFlag, shellProfile)

		// Wire hooks
		if len(cfg.Hooks) > 0 {
			coreHooks := make([]core.HookConfig, len(cfg.Hooks))
			for i, h := range cfg.Hooks {
				coreHooks[i] = core.HookConfig{
					Event:   h.Event,
					Type:    h.Type,
					Command: h.Command,
					URL:     h.URL,
					Timeout: h.Timeout,
					Async:   h.Async,
				}
			}
			engine.SetHooks(core.NewHookManager(proj.Name, coreHooks, shell, shellFlag, shellProfile))
		}

		// Wire local reference normalization / rendering
		engine.SetReferenceConfig(core.ReferenceRenderCfg{
			NormalizeAgents: proj.References.NormalizeAgents,
			RenderPlatforms: proj.References.RenderPlatforms,
			DisplayPath:     proj.References.DisplayPath,
			MarkerStyle:     proj.References.MarkerStyle,
			EnclosureStyle:  proj.References.EnclosureStyle,
		})

		// Wire streaming preview
		{
			spcfg := core.DefaultStreamPreviewCfg()
			if cfg.StreamPreview.Enabled != nil {
				spcfg.Enabled = *cfg.StreamPreview.Enabled
			}
			if cfg.StreamPreview.IntervalMs != nil {
				spcfg.IntervalMs = *cfg.StreamPreview.IntervalMs
			}
			if cfg.StreamPreview.MinDeltaChars != nil {
				spcfg.MinDeltaChars = *cfg.StreamPreview.MinDeltaChars
			}
			if cfg.StreamPreview.MaxChars != nil {
				spcfg.MaxChars = *cfg.StreamPreview.MaxChars
			}
			if cfg.StreamPreview.DisabledPlatforms != nil {
				spcfg.DisabledPlatforms = cfg.StreamPreview.DisabledPlatforms
			}
			engine.SetStreamPreviewCfg(spcfg)
		}

		// Wire instant reply
		if cfg.InstantReply.Enabled != nil && *cfg.InstantReply.Enabled {
			engine.SetInstantReply(core.InstantReplyCfg{
				Enabled: true,
				Content: cfg.InstantReply.Content,
			})
		}

		// Wire rate limiting
		{
			maxMsg := 20
			windowSecs := 60
			if cfg.RateLimit.MaxMessages != nil {
				maxMsg = *cfg.RateLimit.MaxMessages
			}
			if cfg.RateLimit.WindowSecs != nil {
				windowSecs = *cfg.RateLimit.WindowSecs
			}
			if maxMsg > 0 {
				engine.SetRateLimitCfg(core.RateLimitCfg{
					MaxMessages: maxMsg,
					Window:      time.Duration(windowSecs) * time.Second,
				})
			}
		}
		// Wire outgoing rate limiting
		{
			var maxPS float64
			if cfg.OutgoingRateLimit.MaxPerSecond != nil {
				maxPS = *cfg.OutgoingRateLimit.MaxPerSecond
			}
			var burst int
			if cfg.OutgoingRateLimit.Burst != nil {
				burst = *cfg.OutgoingRateLimit.Burst
			}
			defaults := core.OutgoingRateLimitCfg{MaxPerSecond: maxPS, Burst: burst}
			overrides := make(map[string]core.OutgoingRateLimitCfg)
			for name, pc := range cfg.OutgoingRateLimit.Platforms {
				var mps float64
				if pc.MaxPerSecond != nil {
					mps = *pc.MaxPerSecond
				}
				var b int
				if pc.Burst != nil {
					b = *pc.Burst
				}
				overrides[name] = core.OutgoingRateLimitCfg{MaxPerSecond: mps, Burst: b}
			}
			if maxPS > 0 || len(overrides) > 0 {
				engine.SetOutgoingRateLimitCfg(defaults, overrides)
			}
		}

		engine.SetDisplaySaveFunc(func(mode *string, thinkingMessages *bool, thinkingMaxLen, toolMaxLen *int, toolMessages *bool) error {
			return config.SaveDisplayConfig(mode, thinkingMessages, thinkingMaxLen, toolMaxLen, toolMessages)
		})

		// Wire idle timeout
		if cfg.IdleTimeoutMins != nil {
			mins := *cfg.IdleTimeoutMins
			if mins <= 0 {
				engine.SetEventIdleTimeout(0)
			} else {
				engine.SetEventIdleTimeout(time.Duration(mins) * time.Minute)
			}
		}

		// Wire max turn time (absolute per-turn wall-clock cap; 0 = disabled)
		if cfg.MaxTurnTimeMins != nil && *cfg.MaxTurnTimeMins > 0 {
			engine.SetMaxTurnTime(time.Duration(*cfg.MaxTurnTimeMins) * time.Minute)
		}

		// Wire queue depth
		if cfg.Queue.MaxDepth != nil && *cfg.Queue.MaxDepth > 0 {
			engine.SetMaxQueuedMessages(*cfg.Queue.MaxDepth)
		}

		// Wire auto-compress settings
		if proj.AutoCompress.Enabled != nil && *proj.AutoCompress.Enabled {
			minGap := 30 * time.Minute
			if proj.AutoCompress.MinGapMins != nil {
				minGap = time.Duration(*proj.AutoCompress.MinGapMins) * time.Minute
			}
			maxTokens := derefInt(proj.AutoCompress.MaxTokens)
			if maxTokens <= 0 {
				maxTokens = 12000
			}
			engine.SetAutoCompressConfig(true, maxTokens, minGap)
		}
		resetIdle, defaulted := resolveResetOnIdle(proj.ResetOnIdleMins)
		engine.SetResetOnIdle(resetIdle)
		if defaulted {
			slog.Info("project: reset_on_idle_mins not set, applying default — set reset_on_idle_mins = 0 to opt out, see docs/usage.md",
				"project", proj.Name, "default_minutes", defaultResetOnIdleMins)
		}
		if proj.AgentSessionIdleTimeoutMins != nil {
			mins := *proj.AgentSessionIdleTimeoutMins
			if mins <= 0 {
				engine.SetAgentSessionIdleTimeout(0)
			} else {
				engine.SetAgentSessionIdleTimeout(time.Duration(mins) * time.Minute)
			}
		}

		// Wire sender injection
		if proj.InjectSender != nil {
			engine.SetInjectSender(*proj.InjectSender)
		}

		// Wire speech-to-text if enabled
		if cfg.Speech.Enabled {
			speechCfg := core.SpeechCfg{
				Enabled:  true,
				Language: cfg.Speech.Language,
			}
			switch cfg.Speech.Provider {
			case "groq":
				apiKey := cfg.Speech.Groq.APIKey
				model := cfg.Speech.Groq.Model
				if model == "" {
					model = "whisper-large-v3-turbo"
				}
				if apiKey != "" {
					speechCfg.STT = core.NewOpenAIWhisper(apiKey, "https://api.groq.com/openai/v1", model)
				} else {
					slog.Warn("speech: groq provider enabled but api_key is empty")
				}
			case "qwen":
				apiKey := cfg.Speech.Qwen.APIKey
				baseURL := cfg.Speech.Qwen.BaseURL
				model := cfg.Speech.Qwen.Model
				if apiKey != "" {
					speechCfg.STT = core.NewQwenASR(apiKey, baseURL, model)
				} else {
					slog.Warn("speech: qwen provider enabled but api_key is empty")
				}
			case "gemini":
				apiKey := cfg.Speech.Gemini.APIKey
				model := cfg.Speech.Gemini.Model
				if apiKey != "" {
					speechCfg.STT = core.NewGeminiSTT(apiKey, model)
				} else {
					slog.Warn("speech: gemini provider enabled but api_key is empty")
				}
			default: // "openai" or unspecified
				apiKey := cfg.Speech.OpenAI.APIKey
				baseURL := cfg.Speech.OpenAI.BaseURL
				model := cfg.Speech.OpenAI.Model
				if apiKey != "" {
					speechCfg.STT = core.NewOpenAIWhisper(apiKey, baseURL, model)
				} else {
					slog.Warn("speech: openai provider enabled but api_key is empty")
				}
			}
			if speechCfg.STT != nil {
				engine.SetSpeechConfig(speechCfg)
				slog.Info("speech: enabled", "provider", cfg.Speech.Provider)
			}
		}

		// Wire text-to-speech if enabled
		ttsEffective := config.ResolveTTSConfigForProject(cfg.TTS, proj.Name)
		if ttsEffective.Enabled {
			ttsCfg := &core.TTSCfg{
				Enabled:      true,
				Voice:        ttsEffective.Voice,
				LanguageType: ttsEffective.LanguageType,
				Speed:        ttsEffective.Speed,
				MaxTextLen:   ttsEffective.MaxTextLen,
			}
			initMode := ttsEffective.TTSMode
			switch initMode {
			case "always", "voice_only":
			case "":
				initMode = "voice_only"
			default:
				slog.Warn("tts: invalid tts_mode in config, falling back to voice_only", "tts_mode", initMode)
				initMode = "voice_only"
			}
			ttsCfg.SetTTSMode(initMode)
			switch ttsEffective.Provider {
			case "qwen":
				apiKey := cfg.TTS.Qwen.APIKey
				baseURL := cfg.TTS.Qwen.BaseURL
				model := cfg.TTS.Qwen.Model
				if apiKey != "" {
					ttsCfg.TTS = core.NewQwenTTS(apiKey, baseURL, model, nil)
					ttsCfg.Provider = "qwen"
				} else {
					slog.Warn("tts: qwen provider enabled but api_key is empty")
				}
			case "minimax":
				apiKey := cfg.TTS.MiniMax.APIKey
				baseURL := cfg.TTS.MiniMax.BaseURL
				model := cfg.TTS.MiniMax.Model
				if apiKey == "" {
					localCfg, err := config.LoadMiniMaxLocalConfig(cfg.DataDir, cfg.TTS.MiniMax.ConfigFile)
					if err != nil {
						slog.Warn("tts: failed to load minimax local config", "error", err)
					} else {
						apiKey = localCfg.APIKey
						if baseURL == "" {
							if localCfg.BaseURL != "" {
								baseURL = localCfg.BaseURL
							} else if localCfg.APIHost != "" {
								baseURL = localCfg.APIHost
							}
						}
					}
				}
				if apiKey != "" {
					ttsCfg.TTS = core.NewMiniMaxTTS(apiKey, baseURL, model, nil)
					ttsCfg.Provider = "minimax"
				} else {
					slog.Warn("tts: minimax provider enabled but api_key is empty")
				}
			case "mimo":
				apiKey := cfg.TTS.Mimo.APIKey
				baseURL := cfg.TTS.Mimo.BaseURL
				model := cfg.TTS.Mimo.Model
				if apiKey != "" {
					ttsCfg.TTS = core.NewMimoTTS(apiKey, baseURL, model, nil)
					ttsCfg.Provider = "mimo"
				} else {
					slog.Warn("tts: mimo provider enabled but api_key is empty")
				}
			case "espeak":
				voice := ttsEffective.Voice
				if voice == "" {
					voice = "zh" // default to Chinese
				}
				ttsCfg.TTS = core.NewEspeakTTS("", voice)
				ttsCfg.Provider = "espeak"
			case "pico":
				voice := ttsEffective.Voice
				if voice == "" {
					voice = "zh-CN" // default to Chinese (Simplified)
				}
				ttsCfg.TTS = core.NewPicoTTS("", voice)
				ttsCfg.Provider = "pico"
			case "edge":
				voice := ttsEffective.Voice
				if voice == "" {
					voice = "zh-CN-XiaoxiaoNeural" // default Chinese neural voice
				}
				ttsCfg.TTS = core.NewEdgeTTS(voice)
				ttsCfg.Provider = "edge"
			default: // "openai" or unspecified
				apiKey := cfg.TTS.OpenAI.APIKey
				baseURL := cfg.TTS.OpenAI.BaseURL
				model := cfg.TTS.OpenAI.Model
				if apiKey != "" {
					ttsCfg.TTS = core.NewOpenAITTS(apiKey, baseURL, model, nil)
					ttsCfg.Provider = "openai"
				} else {
					slog.Warn("tts: openai provider enabled but api_key is empty")
				}
			}
			if ttsCfg.TTS != nil {
				engine.SetTTSConfig(ttsCfg)
				engine.SetTTSSaveFunc(func(mode string) error {
					return config.SaveTTSMode(mode)
				})
				slog.Info("tts: enabled", "provider", ttsCfg.Provider, "voice", ttsCfg.Voice, "mode", initMode)
			}
		}

		// Set up save callback for auto-detected language
		if lang == core.LangAuto {
			engine.SetLanguageSaveFunc(func(l core.Language) error {
				return config.SaveLanguage(string(l))
			})
		}

		// Wire config reload
		capturedEngine := engine
		capturedProjName := proj.Name
		engine.SetConfigReloadFunc(func() (*core.ConfigReloadResult, error) {
			return reloadConfig(configPath, capturedProjName, capturedEngine)
		})

		engines = append(engines, engine)
	}

	var startErrors []error
	for _, e := range engines {
		if err := e.Start(); err != nil {
			slog.Warn("engine start partially failed (some platforms may be unavailable)", "error", err)
			startErrors = append(startErrors, err)
		}
	}
	// Only exit if ALL engines failed to start
	if len(startErrors) > 0 && len(startErrors) == len(engines) {
		slog.Error("all engines failed to start, exiting")
		os.Exit(1)
	}

	// 业务 HTTP 只在 control 指定的私有 Unix Socket 上提供。
	var mgmtSrv *core.ManagementServer
	var mgmtListener net.Listener
	serverSocket := strings.TrimSpace(rootOpts.serverSocket)
	if serverSocket == "" {
		serverSocket = strings.TrimSpace(os.Getenv("CC_SERVER_SOCKET"))
	}
	if serverSocket != "" {
		mgmtSrv = core.NewManagementServer()
		for i, e := range engines {
			mgmtSrv.RegisterEngine(cfg.Projects[i].Name, e)
		}
		mgmtListener, err = listenPrivateUnixSocket(serverSocket)
		if err != nil {
			slog.Error("private business socket unavailable", "error", err)
			os.Exit(1)
		}
		go func() {
			if err := mgmtSrv.ServeControl(mgmtListener); err != nil {
				slog.Error("private control server stopped", "error", err)
			}
		}()
	}

	slog.Info("cc-connect is running", "projects", len(engines))

	// After startup, check if we were restarted and queue the success
	// notification. The engine dispatches it on the first OnPlatformReady
	// for the target platform (or with a 10s safety timeout), so async
	// platforms that need 2-3s to actually connect (e.g. Telegram) do not
	// silently drop the notify. See issue #1383.
	if notify := core.ConsumeRestartNotify(cfg.DataDir); notify != nil {
		slog.Info("post-restart: queuing success notification", "platform", notify.Platform, "session", notify.SessionKey)
		for _, e := range engines {
			e.SetPendingRestartNotify(notify)
		}
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	var restartReq *core.RestartRequest
	select {
	case <-sigCh:
	case req := <-core.RestartCh:
		restartReq = &req
		slog.Info("restart requested via /restart command", "session", req.SessionKey, "platform", req.Platform)
	}

	slog.Info("shutting down...")
	if mgmtSrv != nil {
		mgmtSrv.Stop()
	}
	if mgmtListener != nil {
		_ = mgmtListener.Close()
		_ = os.Remove(serverSocket)
	}
	for _, e := range engines {
		if err := e.Stop(); err != nil {
			slog.Error("shutdown error", "error", err)
		}
	}
	if logCloser != nil {
		logCloser.Close()
	}
	instanceLock.Release()

	if restartReq != nil {
		if err := core.SaveRestartNotify(cfg.DataDir, *restartReq); err != nil {
			slog.Error("restart: save notify failed", "error", err)
		}
		if err := requestControlledRestart(rootOpts.runtimeSocket); err != nil {
			slog.Error("restart: control request failed", "error", err)
		}
	}

	slog.Info("bye")
}

func finalizeProjectPlatforms(project string, agent core.Agent, configured []core.Platform) ([]core.Platform, error) {
	platforms := configured
	if _, authoritative := agent.(core.AuthoritativeSessionHistory); authoritative {
		platforms = append([]core.Platform{core.NewManagementPlatform()}, platforms...)
	}
	if len(platforms) == 0 {
		return nil, fmt.Errorf("project %q agent %q has no configured platform and does not support management sessions", project, agent.Name())
	}
	return platforms, nil
}

func runTopLevelCommand(args []string) bool {
	if len(args) == 0 {
		return false
	}
	handler, ok := topLevelCommandHandlers[args[0]]
	if !ok {
		return false
	}
	handler(args[1:])
	return true
}

type rootCLIOptions struct {
	configPath    string
	force         bool
	logMaxSize    string
	logMaxBackups int
	showVersion   bool
	runtimeSocket string
	serverSocket  string
	args          []string
}

func parseRootCLIOptions(args []string) (rootCLIOptions, error) {
	fs := flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = printUsage

	configPath := fs.String("config", "", "path to config file (default: ./config.toml or ~/.cc-connect/config.toml)")
	force := fs.Bool("force", false, "kill any existing instance with the same config before starting")
	logMaxSize := fs.String("log-max-size", "", "max bytes for the rotating log file (e.g. 10MB, 512K, 10485760); overrides CC_LOG_MAX_SIZE env var (default: 10MB)")
	logMaxBackups := fs.Int("log-max-backups", 0, "number of rotated log files to retain (.log.1 .. .log.N); overrides CC_LOG_MAX_BACKUPS env var (default: 3)")
	showVersion := fs.Bool("version", false, "print version and exit")
	runtimeSocket := fs.String("runtime-socket", "", "private control Runtime Unix socket")
	serverSocket := fs.String("server-socket", "", "private business HTTP Unix socket")

	if err := fs.Parse(args); err != nil {
		return rootCLIOptions{}, err
	}

	return rootCLIOptions{
		configPath:    *configPath,
		force:         *force,
		logMaxSize:    *logMaxSize,
		logMaxBackups: *logMaxBackups,
		showVersion:   *showVersion,
		runtimeSocket: *runtimeSocket,
		serverSocket:  *serverSocket,
		args:          fs.Args(),
	}, nil
}

func validateNoExtraTopLevelArgs(args []string) error {
	if len(args) == 0 {
		return nil
	}
	return fmt.Errorf("unknown top-level command: %s", args[0])
}

func validateCodexProductConfig(cfg *config.Config) error {
	if cfg == nil {
		return errors.New("Codex 专用版配置不能为空")
	}
	if len(cfg.Projects) != 1 {
		return fmt.Errorf("Codex 专用版只允许一个内部 Runtime 项目，当前为 %d 个；Codex 项目由 Desktop App 的 list_projects 提供", len(cfg.Projects))
	}
	if len(cfg.Providers) > 0 || strings.TrimSpace(cfg.ProviderPresetsURL) != "" {
		return errors.New("Codex 专用版不支持 Provider 配置；模型与凭据由 Codex Desktop App 管理，请删除 [[providers]] 和 provider_presets_url")
	}
	if len(cfg.Commands) > 0 || len(cfg.Aliases) > 0 || len(cfg.Hooks) > 0 {
		return errors.New("Codex 专用版不支持自定义 commands、aliases 或 hooks，请从配置中删除")
	}
	if cfg.Cron.Silent != nil || strings.TrimSpace(cfg.Cron.SessionMode) != "" {
		return errors.New("Codex 专用版不支持 [cron]，请从配置中删除")
	}
	if cfg.Webhook.Enabled != nil || cfg.Webhook.Port != 0 || cfg.Webhook.Token != "" || cfg.Webhook.Path != "" {
		return errors.New("Codex 专用版不支持 [webhook]，请从配置中删除")
	}
	if cfg.Bridge.Enabled != nil || cfg.Bridge.Port != 0 || cfg.Bridge.Token != "" || cfg.Bridge.Path != "" || len(cfg.Bridge.CORSOrigins) > 0 || cfg.Bridge.Insecure != nil {
		return errors.New("Codex 专用版不支持 [bridge]，Web 仅作为内部管理传输，请从配置中删除")
	}
	if cfg.Speech.Enabled || cfg.TTS.Enabled {
		return errors.New("Codex 专用版不支持 speech 或 tts 配置，请从配置中删除")
	}
	if cfg.Relay.TimeoutSecs != nil || strings.TrimSpace(cfg.Relay.Visibility) != "" {
		return errors.New("Codex 专用版不支持 [relay]，请从配置中删除")
	}

	project := cfg.Projects[0]
	if !strings.EqualFold(strings.TrimSpace(project.Agent.Type), "codexapp") {
		return fmt.Errorf("Codex 专用版只支持 agent.type = %q，当前为 %q；不提供 CLI 或 App Server fallback", "codexapp", project.Agent.Type)
	}
	if len(project.Agent.Providers) > 0 || len(project.Agent.ProviderRefs) > 0 {
		return errors.New("Codex 专用版不支持项目 Provider 配置，请删除 projects.agent.providers 和 provider_refs")
	}
	for index, platform := range project.Platforms {
		if strings.TrimSpace(platform.Type) != "feishu" {
			return fmt.Errorf("Codex 专用版只支持飞书平台 type = %q，projects[0].platforms[%d] 当前为 %q；Lark 与其他平台不兼容", "feishu", index, platform.Type)
		}
	}
	if project.Heartbeat.Enabled != nil || project.Heartbeat.IntervalMins != nil || project.Heartbeat.OnlyWhenIdle != nil || project.Heartbeat.SessionKey != "" || project.Heartbeat.Prompt != "" || project.Heartbeat.Silent != nil || project.Heartbeat.TimeoutMins != nil {
		return errors.New("Codex 专用版不支持 projects.heartbeat，请从配置中删除")
	}
	if project.Observe != nil {
		return errors.New("Codex 专用版不支持 projects.observe，请从配置中删除")
	}
	if project.RunAsUser != "" || len(project.RunAsEnv) > 0 {
		return errors.New("Codex 专用版不启动本地 Agent 子进程，不支持 run_as_user 或 run_as_env，请从配置中删除")
	}
	return nil
}

func configuredLanguage(value string) core.Language {
	switch value {
	case "zh", "chinese":
		return core.LangChinese
	case "zh-TW", "zh_TW", "zhtw":
		return core.LangTraditionalChinese
	case "ja", "japanese":
		return core.LangJapanese
	case "es", "spanish":
		return core.LangSpanish
	case "en", "english":
		return core.LangEnglish
	default:
		return core.LangAuto
	}
}

func listenPrivateUnixSocket(path string) (net.Listener, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil, fmt.Errorf("private socket path is required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return nil, fmt.Errorf("create private socket directory: %w", err)
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("private socket path exists and is not a socket: %s", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, fmt.Errorf("remove stale private socket: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect private socket: %w", err)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("listen private socket: %w", err)
	}
	if err := os.Chmod(path, 0o660); err != nil {
		_ = listener.Close()
		return nil, fmt.Errorf("protect private socket: %w", err)
	}
	return listener, nil
}

// sessionStorePath builds a unique filename from project name + work_dir.
// It checks for legacy session files (without the sessions/ subdirectory) in dataDir
// for backward compatibility; if found, uses that path. Otherwise uses dataDir/sessions/.
func sessionStorePath(dataDir, name, workDir string) string {
	var filename string
	if workDir == "" {
		filename = name + ".json"
	} else {
		abs, err := filepath.Abs(workDir)
		if err != nil {
			abs = workDir
		}
		h := sha256.Sum256([]byte(abs))
		short := hex.EncodeToString(h[:4])
		filename = fmt.Sprintf("%s_%s.json", name, short)
	}

	// Check legacy path in dataDir (without sessions/ subdirectory) for backward compatibility.
	// Also check for the older .sessions.json naming convention.
	for _, legacy := range []string{
		filepath.Join(dataDir, filename),
		filepath.Join(dataDir, strings.TrimSuffix(filename, ".json")+".sessions.json"),
	} {
		if _, err := os.Stat(legacy); err == nil {
			slog.Info("session: using legacy file in dataDir", "path", legacy)
			return legacy
		}
	}

	return filepath.Join(dataDir, "sessions", filename)
}

func projectStatePath(dataDir, projectName string) string {
	replacer := strings.NewReplacer(
		"\\", "_",
		"/", "_",
		":", "_",
		"*", "_",
		"?", "_",
		"\"", "_",
		"<", "_",
		">", "_",
		"|", "_",
	)
	name := strings.TrimSpace(projectName)
	name = replacer.Replace(name)
	if name == "" {
		name = "project"
	}
	return filepath.Join(dataDir, "projects", name+".state.json")
}

func applyProjectStateOverride(projectName string, agent core.Agent, configuredWorkDir string, store *core.ProjectStateStore) string {
	effectiveWorkDir := configuredWorkDir
	if store == nil {
		return effectiveWorkDir
	}

	switcher, ok := agent.(core.WorkDirSwitcher)
	if !ok {
		return effectiveWorkDir
	}

	override := store.WorkDirOverride()
	if override == "" {
		return effectiveWorkDir
	}
	if abs, err := filepath.Abs(override); err == nil {
		override = abs
	}

	info, err := os.Stat(override)
	if err != nil || !info.IsDir() {
		slog.Warn("project_state: ignoring invalid work_dir override", "project", projectName, "work_dir", override)
		return effectiveWorkDir
	}

	switcher.SetWorkDir(override)
	slog.Info("project_state: applied work_dir override", "project", projectName, "work_dir", override)
	return override
}

// resolveClaudeProjectDir returns the Claude Code project directory for a given
// work directory, or "" if it doesn't exist.
func resolveClaudeProjectDir(workDir string) string {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	// Claude Code encodes paths by replacing os.PathSeparator with "-"
	// e.g. /home/leigh/workspace/cc-connect -> -home-leigh-workspace-cc-connect
	encoded := strings.ReplaceAll(workDir, string(os.PathSeparator), "-")
	dir := filepath.Join(homeDir, ".claude", "projects", encoded)
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return ""
	}
	return dir
}

// resolveConfigPath determines which config file to use.
// Priority: explicit flag → ./config.toml → ~/.cc-connect/config.toml
func resolveConfigPath(explicit string) string {
	if explicit != "" {
		return explicit
	}
	if _, err := os.Stat("config.toml"); err == nil {
		return "config.toml"
	}
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".cc-connect", "config.toml")
	}
	return "config.toml"
}

func bootstrapConfig(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	const tmpl = `# CC-Connect Codex Desktop App configuration
# Docs: https://github.com/shusfun/cc-connect

[log]
level = "info"

[[projects]]
name = "my-project"

[projects.agent]
type = "codexapp"

[projects.agent.options]
work_dir = "/path/to/your/project"
# Feishu (WebSocket, no public IP needed)
[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "your-feishu-app-id"
app_secret = "your-feishu-app-secret"
`
	return os.WriteFile(path, []byte(tmpl), 0o644)
}

func printUsage() {
	v := version
	if v == "" || v == "dev" {
		v = "dev"
	}

	fmt.Fprintf(os.Stderr, `
                                              _
  ___ ___        ___ ___  _ __  _ __   ___  ___| |_
 / __/ __|_____ / __/ _ \| '_ \| '_ \ / _ \/ __| __|
| (_| (_|_____|  (_| (_) | | | | | | |  __/ (__| |_
 \___\__|      \___\___/|_| |_|_| |_|\___|\___|\__|  %s

  Codex Desktop App remote companion for Web and Feishu.
  Codex Desktop App remains the only owner of projects, tasks, turns and writes.

  GitHub:  https://github.com/shusfun/cc-connect
  Docs:    https://github.com/shusfun/cc-connect/blob/main/INSTALL.md

Usage:
  cc-connect [flags]
  cc-connect <command> [args]

Flags:
  --config <path>    Path to config file (default: ./config.toml or ~/.cc-connect/config.toml)
  --force            Kill any existing instance with the same config before starting
  --version          Print version and exit
  --help             Show this help message

Commands:
  config-example     Print the embedded configuration reference

Examples:
  cc-connect                          Start with default config
  cc-connect --config /path/to.toml   Start with a specific config file
  cc-connect config-example           Print the configuration reference

`, v)
}

func requestControlledRestart(runtimeSocket string) error {
	runtimeSocket = strings.TrimSpace(runtimeSocket)
	if runtimeSocket == "" {
		runtimeSocket = strings.TrimSpace(os.Getenv("CC_RUNTIME_SOCKET"))
	}
	if runtimeSocket == "" {
		return errors.New("control Runtime Unix socket is required")
	}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", runtimeSocket)
	}}
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	request, err := http.NewRequest(http.MethodPost, "http://cc-connect-control/control/v1/service/restart", nil)
	if err != nil {
		return err
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode != http.StatusAccepted {
		return fmt.Errorf("control restart status %s", response.Status)
	}
	return nil
}

func setupLogger(level string, w io.Writer) {
	var logLevel slog.Level
	switch level {
	case "debug":
		logLevel = slog.LevelDebug
	case "warn":
		logLevel = slog.LevelWarn
	case "error":
		logLevel = slog.LevelError
	default:
		logLevel = slog.LevelInfo
	}
	if w == nil {
		w = os.Stdout
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{
		Level: logLevel,
	})))
}

// reloadConfig re-reads config.toml and applies hot-reloadable settings
// (display, providers, commands) to the given engine.
func reloadConfig(configPath, projName string, engine *core.Engine) (*core.ConfigReloadResult, error) {
	cfg, err := config.Load(configPath)
	if err != nil {
		return nil, fmt.Errorf("reload config: %w", err)
	}
	if err := validateCodexProductConfig(cfg); err != nil {
		return nil, fmt.Errorf("reload config: %w", err)
	}

	result := &core.ConfigReloadResult{}

	// Re-apply process-global hot-reloadable settings.
	if globalAPIServer != nil {
		globalAPIServer.SetMaxAttachmentSize(resolveMaxAttachmentSize(cfg))
	}

	// Find the matching project
	var proj *config.ProjectConfig
	for i := range cfg.Projects {
		if cfg.Projects[i].Name == projName {
			proj = &cfg.Projects[i]
			break
		}
	}
	if proj == nil {
		return nil, fmt.Errorf("project %q not found in config", projName)
	}

	// Reload display config (includes legacy quiet → display mapping)
	mode, tm, tool, tmlen, toollen, showCtx, showFooter, hideAgentFooter := config.EffectiveDisplay(cfg, proj)
	historyMaxLen := config.EffectiveHistoryMaxLen(cfg, proj)
	engine.SetDisplayConfig(core.DisplayCfg{
		Mode:             mode,
		CardMode:         config.EffectiveCardMode(cfg, proj),
		ThinkingMessages: tm,
		ThinkingMaxLen:   tmlen,
		ToolMaxLen:       toollen,
		ToolMessages:     tool,
		HistoryMaxLen:    &historyMaxLen,
		HideAgentFooter:  hideAgentFooter,
	})
	result.DisplayUpdated = true

	// Wire show_context_indicator and reply_footer from display config
	engine.SetShowContextIndicator(showCtx)
	showWorkdir := true
	if proj.ShowWorkdirIndicator != nil {
		showWorkdir = *proj.ShowWorkdirIndicator
	}
	engine.SetShowWorkdirIndicator(showWorkdir)
	engine.SetReplyFooterEnabled(showFooter)

	// Reload auto-compress settings
	if proj.AutoCompress.Enabled != nil && *proj.AutoCompress.Enabled {
		minGap := 30 * time.Minute
		if proj.AutoCompress.MinGapMins != nil {
			minGap = time.Duration(*proj.AutoCompress.MinGapMins) * time.Minute
		}
		maxTokens := derefInt(proj.AutoCompress.MaxTokens)
		if maxTokens <= 0 {
			maxTokens = 12000
		}
		engine.SetAutoCompressConfig(true, maxTokens, minGap)
	} else {
		engine.SetAutoCompressConfig(false, 0, 0)
	}
	resetIdle, defaulted := resolveResetOnIdle(proj.ResetOnIdleMins)
	engine.SetResetOnIdle(resetIdle)
	if defaulted {
		slog.Info("project: reset_on_idle_mins not set, applying default — set reset_on_idle_mins = 0 to opt out, see docs/usage.md",
			"project", proj.Name, "default_minutes", defaultResetOnIdleMins)
	}
	if proj.AgentSessionIdleTimeoutMins != nil {
		mins := *proj.AgentSessionIdleTimeoutMins
		if mins <= 0 {
			engine.SetAgentSessionIdleTimeout(0)
		} else {
			engine.SetAgentSessionIdleTimeout(time.Duration(mins) * time.Minute)
		}
	} else {
		// A reload may remove this option after timers were scheduled; reset
		// explicitly so those stale idle-close timers cannot fire later.
		engine.SetAgentSessionIdleTimeout(0)
	}

	// Reload instant reply
	if cfg.InstantReply.Enabled != nil && *cfg.InstantReply.Enabled {
		engine.SetInstantReply(core.InstantReplyCfg{
			Enabled: true,
			Content: cfg.InstantReply.Content,
		})
	} else {
		engine.SetInstantReply(core.InstantReplyCfg{})
	}

	// Reload sender injection
	engine.SetInjectSender(proj.InjectSender != nil && *proj.InjectSender)

	// Reload attachment send-back switch
	engine.SetAttachmentSendEnabled(cfg.AttachmentSend != "off")

	// Reload filter_external_sessions
	engine.SetFilterExternalSessions(proj.FilterExternalSessions != nil && *proj.FilterExternalSessions)

	// Reload providers
	if ps, ok := engine.GetAgent().(core.ProviderSwitcher); ok {
		providers := make([]core.ProviderConfig, len(proj.Agent.Providers))
		for i, p := range proj.Agent.Providers {
			providers[i] = configProviderToCore(p)
		}
		ps.SetProviders(providers)
		result.ProvidersUpdated = len(providers)

		if active, _ := proj.Agent.Options["provider"].(string); active != "" {
			ps.SetActiveProvider(active)
		}
	}

	// Reload custom commands
	engine.ClearCommands("config")
	for _, c := range cfg.Commands {
		engine.AddCommand(c.Name, c.Description, c.Prompt, c.Exec, c.WorkDir, "config")
	}
	result.CommandsUpdated = len(cfg.Commands)

	// Reload aliases
	engine.ClearAliases()
	for _, a := range cfg.Aliases {
		engine.AddAlias(a.Name, a.Command)
	}

	// Reload banned words
	engine.SetBannedWords(cfg.BannedWords)

	// Reload disabled commands
	engine.SetDisabledCommands(proj.DisabledCommands)

	// Reload admin allowlist
	engine.SetAdminFrom(proj.AdminFrom)

	// Reload per-user role-based policies
	if proj.Users != nil {
		engine.SetUserRoles(buildUserRoleManager(proj.Users))
	} else {
		engine.SetUserRoles(nil)
	}

	slog.Info("config reloaded", "project", projName)
	return result, nil
}

func buildUserRoleManager(uc *config.UsersConfig) *core.UserRoleManager {
	var roles []core.RoleInput
	for name, rc := range uc.Roles {
		var rlCfg *core.RateLimitCfg
		if rc.RateLimit != nil {
			maxMsg, windowSecs := 20, 60
			if rc.RateLimit.MaxMessages != nil {
				maxMsg = *rc.RateLimit.MaxMessages
			}
			if rc.RateLimit.WindowSecs != nil {
				windowSecs = *rc.RateLimit.WindowSecs
			}
			rlCfg = &core.RateLimitCfg{
				MaxMessages: maxMsg,
				Window:      time.Duration(windowSecs) * time.Second,
			}
		}
		roles = append(roles, core.RoleInput{
			Name:             name,
			UserIDs:          rc.UserIDs,
			DisabledCommands: rc.DisabledCommands,
			RateLimit:        rlCfg,
		})
	}
	defaultRole := "member"
	if uc.DefaultRole != "" {
		defaultRole = uc.DefaultRole
	}
	urm := core.NewUserRoleManager()
	urm.Configure(defaultRole, roles)
	return urm
}

func configProviderToCore(p config.ProviderConfig) core.ProviderConfig {
	c := core.ProviderConfig{
		Name: p.Name, APIKey: p.APIKey, BaseURL: p.BaseURL,
		Model: p.Model, Models: convertProviderModels(p.Models),
		Thinking: p.Thinking, Env: p.Env,
	}
	if p.Codex != nil {
		c.CodexWireAPI = p.Codex.WireAPI
		c.CodexHTTPHeaders = p.Codex.HTTPHeaders
	}
	return c
}

func convertProviderModels(ms []config.ProviderModelConfig) []core.ModelOption {
	if len(ms) == 0 {
		return nil
	}
	opts := make([]core.ModelOption, len(ms))
	for i, m := range ms {
		opts[i] = core.ModelOption{Name: m.Model, Alias: m.Alias}
	}
	return opts
}

func buildAgentOptions(dataDir string, proj config.ProjectConfig) map[string]any {
	opts := make(map[string]any, len(proj.Agent.Options)+2)
	for k, v := range proj.Agent.Options {
		opts[k] = v
	}
	opts["cc_data_dir"] = dataDir
	opts["cc_project"] = proj.Name
	return opts
}

func convertCoreModels(ms []core.ModelOption) []config.ProviderModelConfig {
	if len(ms) == 0 {
		return nil
	}
	out := make([]config.ProviderModelConfig, len(ms))
	for i, m := range ms {
		out[i] = config.ProviderModelConfig{Model: m.Name, Alias: m.Alias}
	}
	return out
}

func buildHeartbeatConfig(hc config.HeartbeatConfig) core.HeartbeatConfig {
	cfg := core.HeartbeatConfig{
		IntervalMins: 30,
		OnlyWhenIdle: true,
		Silent:       true,
		TimeoutMins:  30,
		SessionKey:   hc.SessionKey,
		Prompt:       hc.Prompt,
	}
	if hc.Enabled != nil {
		cfg.Enabled = *hc.Enabled
	}
	if hc.IntervalMins != nil {
		cfg.IntervalMins = *hc.IntervalMins
	}
	if hc.OnlyWhenIdle != nil {
		cfg.OnlyWhenIdle = *hc.OnlyWhenIdle
	}
	if hc.Silent != nil {
		cfg.Silent = *hc.Silent
	}
	if hc.TimeoutMins != nil {
		cfg.TimeoutMins = *hc.TimeoutMins
	}
	return cfg
}

func derefInt(v *int) int {
	if v == nil {
		return 0
	}
	return *v
}
