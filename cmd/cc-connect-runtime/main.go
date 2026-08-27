package main

import (
	"context"
	"crypto/ed25519"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/chenhg5/cc-connect/agent/codexapp"
	"github.com/chenhg5/cc-connect/core"
	"github.com/chenhg5/cc-connect/releaseinstall"
	"github.com/chenhg5/cc-connect/runtimeclient"
	"github.com/chenhg5/cc-connect/runtimeidentity"
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
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := runtimeidentity.New(*stateDir)
	if err != nil {
		return err
	}
	if pairing {
		if strings.TrimSpace(*serverURL) == "" || strings.TrimSpace(*pairingCode) == "" {
			return errors.New("pair requires --server and --code")
		}
		privateKey, err := store.LoadOrCreateKey()
		if err != nil {
			return err
		}
		ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
		defer cancel()
		deviceID, err := runtimeclient.Pair(ctx, *serverURL, *pairingCode, *deviceName, privateKey.Public().(ed25519.PublicKey), false)
		if err != nil {
			return err
		}
		if err := store.SaveMetadata(*serverURL, deviceID); err != nil {
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
		return codexapp.BootstrapRuntime(socketPath, strings.TrimSpace(*appNode), args)
	}
	identity, err := store.Load()
	if err != nil {
		return fmt.Errorf("请先在 Web 生成配对码并运行 cc-connect-runtime pair: %w", err)
	}
	releaseClient, err := releaseinstall.New(releaseinstall.Config{})
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
		"socket_path": strings.TrimSpace(*toolsSocket), "node_path": strings.TrimSpace(*appNode),
		"bridge_fd": bridgeFD,
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
	client, err := runtimeclient.NewClient(runtimeclient.ClientConfig{ServerURL: identity.ServerURL, DeviceID: identity.DeviceID, PrivateKey: identity.PrivateKey, Handler: handler, Checkpoint: store})
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
		return err
	case <-updater.RestartRequested():
		return client.Close()
	}
}

func validateCodexRuntime(ctx context.Context, agent core.Agent) error {
	catalog, ok := agent.(core.AgentProjectCatalog)
	if !ok {
		return errors.New("Codex Desktop App 代理缺少项目目录能力")
	}
	projects, err := catalog.ListProjects(ctx)
	if err != nil {
		return fmt.Errorf("无法读取 Codex App 项目状态: %w", err)
	}
	if len(projects) == 0 {
		return errors.New("Codex Desktop App 当前没有可用项目")
	}
	if _, err := agent.ListSessions(ctx); err != nil {
		return fmt.Errorf("无法读取 Codex App 任务状态: %w", err)
	}
	return nil
}

func defaultStateDirectory() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".cc-connect-runtime"
	}
	return filepath.Join(home, "Library", "Application Support", "cc-connect-runtime")
}

func hostname() string {
	name, err := os.Hostname()
	if err != nil || strings.TrimSpace(name) == "" {
		return "Mac"
	}
	return name
}
