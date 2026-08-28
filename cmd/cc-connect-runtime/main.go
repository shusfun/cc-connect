package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/shusfun/cc-connect/agent/codexapp"
	"github.com/shusfun/cc-connect/core"
	"github.com/shusfun/cc-connect/releaseinstall"
	"github.com/shusfun/cc-connect/runtimeclient"
	"github.com/shusfun/cc-connect/runtimecompanion"
	"github.com/shusfun/cc-connect/runtimeidentity"
)

var version = "dev"

func main() {
	if err := run(os.Args[1:]); err != nil {
		slog.Error("cc-connect-runtime failed", "error", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) > 0 && args[0] == "version" {
		fmt.Println(version)
		return nil
	}
	pairing := len(args) > 0 && args[0] == "pair"
	if pairing {
		args = args[1:]
	}
	flags := flag.NewFlagSet("cc-connect-runtime", flag.ContinueOnError)
	stateDir := flags.String("state-dir", defaultStateDirectory(), "Runtime 状态目录（私钥始终保存在 macOS Keychain）")
	serverURL := flags.String("server", "", "control 的公开 HTTPS URL")
	pairingCode := flags.String("code", "", "Web 生成的一次性配对码")
	deviceName := flags.String("name", hostname(), "设备显示名称")
	toolsSocket := flags.String("codex-app-tools-socket", "", "可选 Codex Desktop App tools Socket；默认自动发现")
	appNode := flags.String("codex-app-node", "", "可选 Codex Desktop App 内置 Node 路径")
	cosignBinary := flags.String("cosign", strings.TrimSpace(os.Getenv("COSIGN_BIN")), "用于 Release 验签的 cosign 路径")
	allowInsecureLoopback := flags.Bool("allow-insecure-loopback", false, "仅开发环境允许 loopback HTTP Control")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if pairing {
		if strings.TrimSpace(*serverURL) == "" || strings.TrimSpace(*pairingCode) == "" {
			return errors.New("pair requires --server and --code")
		}
		ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
		defer cancel()
		deviceID, err := runtimecompanion.Pair(ctx, runtimecompanion.PairOptions{
			StateDirectory: *stateDir, ServerURL: *serverURL, Code: *pairingCode, DeviceName: *deviceName,
			AllowInsecureLoopback: *allowInsecureLoopback,
		})
		if err != nil {
			return err
		}
		fmt.Printf("Runtime 已配对：%s\n", deviceID)
		return nil
	}
	bridgeFD, err := codexapp.InheritedBridgeFD()
	if err != nil {
		return err
	}
	if bridgeFD == 0 {
		socketPath := strings.TrimSpace(*toolsSocket)
		if socketPath == "" {
			socketPath = strings.TrimSpace(os.Getenv("CODEX_APP_TOOLS_PIPE_PATH"))
		}
		return codexapp.BootstrapRuntime(socketPath, strings.TrimSpace(*appNode), *stateDir, version, args)
	}
	signal.Ignore(syscall.SIGHUP)
	store, err := runtimeidentity.New(*stateDir)
	if err != nil {
		return err
	}
	identity, err := store.Load()
	if err != nil {
		return fmt.Errorf("请先在 Web 生成配对码并运行 cc-connect-runtime pair: %w", err)
	}
	releaseClient, err := releaseinstall.New(releaseinstall.Config{Cosign: *cosignBinary})
	if err != nil {
		return err
	}
	updater, err := runtimeclient.NewUpdateManager(runtimeclient.UpdateManagerConfig{StateDirectory: *stateDir, ReleaseClient: releaseClient})
	if err != nil {
		return err
	}
	defer func() {
		if rollbackErr := updater.RollbackStartupFailure(); rollbackErr != nil {
			slog.Error("Runtime 未确认更新回滚失败", "error", rollbackErr)
		}
	}()
	agentValue, err := codexapp.New(map[string]any{
		"socket_path": strings.TrimSpace(*toolsSocket), "bridge_fd": bridgeFD,
	})
	if err != nil {
		return err
	}
	defer func() { _ = agentValue.Stop() }()
	if err := validateCodexRuntime(context.Background(), agentValue); err != nil {
		return err
	}
	handler, err := runtimeclient.NewHandler(runtimeclient.Dependencies{Agent: agentValue, Updater: updater})
	if err != nil {
		return err
	}
	reporter, err := runtimecompanion.ReporterFromEnvironment()
	if err != nil {
		return err
	}
	defer func() { _ = reporter.Close() }()
	client, err := runtimeclient.NewClient(runtimeclient.ClientConfig{
		ServerURL: identity.ServerURL, DeviceID: identity.DeviceID, PrivateKey: identity.PrivateKey, Handler: handler, Checkpoint: store,
		AllowInsecureLoopback: *allowInsecureLoopback,
		OnConnectionState: func(state runtimeclient.ConnectionState) {
			if reportErr := reporter.Report(runtimecompanion.WorkerConnectionState{
				Connected: state.Connected, ConnectionGeneration: state.ConnectionGeneration,
			}); reportErr != nil {
				slog.Warn("上报 Runtime 连接状态失败", "error", reportErr)
			}
		},
	})
	if err != nil {
		return err
	}
	defer func() { _ = client.Close() }()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	clientResult := make(chan error, 1)
	go func() { clientResult <- client.Run(ctx) }()
	select {
	case err := <-clientResult:
		return runtimeExitError(ctx, err)
	case <-updater.RestartRequested():
		return client.Close()
	}
}

func runtimeExitError(ctx context.Context, err error) error {
	if ctx.Err() != nil && errors.Is(err, context.Canceled) {
		return nil
	}
	return err
}

func validateCodexRuntime(ctx context.Context, agent core.Agent) error {
	catalog, ok := agent.(core.AgentProjectCatalog)
	if !ok {
		return errors.New("codex Desktop App 代理缺少项目目录能力")
	}
	projects, err := catalog.ListProjects(ctx)
	if err != nil {
		return fmt.Errorf("无法读取 Codex App 项目状态: %w", err)
	}
	if len(projects) == 0 {
		return errors.New("codex Desktop App 当前没有可用项目")
	}
	if _, err := agent.ListSessions(ctx); err != nil {
		return fmt.Errorf("无法读取 Codex App 任务状态: %w", err)
	}
	return nil
}

func defaultStateDirectory() string {
	return runtimecompanion.DefaultStateDirectory()
}

func hostname() string {
	name, err := os.Hostname()
	if err != nil || strings.TrimSpace(name) == "" {
		return "Mac"
	}
	return name
}
