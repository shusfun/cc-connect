package runtimecompanion

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/shusfun/cc-connect/releasecontract"
	"github.com/shusfun/cc-connect/releaseinstall"
	"github.com/shusfun/cc-connect/runtimeclient"
	"github.com/shusfun/cc-connect/runtimeidentity"
)

const (
	StatusSocketName = "status.sock"
	statusProtocol   = 1
)

type SupervisorStatus struct {
	Protocol             int       `json:"protocol"`
	SupervisorPID        int       `json:"supervisor_pid"`
	WorkerPID            int       `json:"worker_pid,omitempty"`
	WorkerGeneration     uint64    `json:"worker_generation"`
	ConnectionGeneration uint64    `json:"connection_generation,omitempty"`
	WorkerRunning        bool      `json:"worker_running"`
	RuntimeConnected     bool      `json:"runtime_connected"`
	ControlURL           string    `json:"control_url,omitempty"`
	DeviceID             string    `json:"device_id,omitempty"`
	Version              string    `json:"version"`
	LastError            string    `json:"last_error,omitempty"`
	LastErrorAt          time.Time `json:"last_error_at,omitempty"`
	UpdatedAt            time.Time `json:"updated_at"`
}

type ReleaseStatus struct {
	ActiveTag       string `json:"active_tag,omitempty"`
	PendingTag      string `json:"pending_tag,omitempty"`
	Pending         bool   `json:"pending"`
	ManifestVersion int    `json:"manifest_version,omitempty"`
}

type DesktopUpdateStatus struct {
	CurrentTag string `json:"current_tag"`
	LatestTag  string `json:"latest_tag"`
	Available  bool   `json:"available"`
}

type PairOptions struct {
	StateDirectory        string
	ServerURL             string
	Code                  string
	DeviceName            string
	AllowInsecureLoopback bool
}

type releaseClient interface {
	LatestTag(context.Context) (string, error)
	Fetch(context.Context, string) (releaseinstall.Release, error)
	DownloadArtifact(context.Context, releaseinstall.Release, releasecontract.Artifact, string) error
}

var openReleaseClient = func(cosign string) (releaseClient, error) {
	return releaseinstall.New(releaseinstall.Config{Cosign: cosign})
}

type socketRequest struct {
	Protocol int    `json:"protocol"`
	Method   string `json:"method"`
}

type socketResponse struct {
	OK     bool              `json:"ok"`
	Status *SupervisorStatus `json:"status,omitempty"`
	Error  string            `json:"error,omitempty"`
}

func DefaultStateDirectory() string {
	if explicit := strings.TrimSpace(os.Getenv("CC_CONNECT_RUNTIME_STATE_DIR")); explicit != "" {
		return filepath.Clean(explicit)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".cc-connect-runtime"
	}
	return filepath.Join(home, "Library", "Application Support", "cc-connect-runtime")
}

func StatusSocketPath(stateDirectory string) string {
	return filepath.Join(stateDirectory, StatusSocketName)
}

func RuntimeLogPath(stateDirectory string) string {
	return filepath.Join(stateDirectory, "logs", "runtime.log")
}

func QueryStatus(ctx context.Context, stateDirectory string) (SupervisorStatus, error) {
	response, err := request(ctx, stateDirectory, "status")
	if err != nil {
		return SupervisorStatus{}, err
	}
	if response.Status == nil {
		return SupervisorStatus{}, errors.New("Runtime supervisor 未返回状态")
	}
	return *response.Status, nil
}

func Reconnect(ctx context.Context, stateDirectory string) error {
	_, err := request(ctx, stateDirectory, "reconnect")
	return err
}

func request(ctx context.Context, stateDirectory, method string) (socketResponse, error) {
	dialer := net.Dialer{Timeout: 2 * time.Second}
	connection, err := dialer.DialContext(ctx, "unix", StatusSocketPath(stateDirectory))
	if err != nil {
		return socketResponse{}, fmt.Errorf("Runtime supervisor 未在线，请从 Codex App 终端启动 launcher: %w", err)
	}
	defer func() { _ = connection.Close() }()
	deadline := time.Now().Add(3 * time.Second)
	_ = connection.SetDeadline(deadline)
	if deadlineFromContext, ok := ctx.Deadline(); ok && deadlineFromContext.Before(deadline) {
		_ = connection.SetDeadline(deadlineFromContext)
	}
	if err := json.NewEncoder(connection).Encode(socketRequest{Protocol: statusProtocol, Method: method}); err != nil {
		return socketResponse{}, fmt.Errorf("发送 Runtime supervisor 请求: %w", err)
	}
	var response socketResponse
	decoder := json.NewDecoder(bufio.NewReader(connection))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&response); err != nil {
		return socketResponse{}, fmt.Errorf("读取 Runtime supervisor 响应: %w", err)
	}
	if !response.OK {
		return socketResponse{}, errors.New(strings.TrimSpace(response.Error))
	}
	return response, nil
}

func Pair(ctx context.Context, options PairOptions) (string, error) {
	stateDirectory := strings.TrimSpace(options.StateDirectory)
	if stateDirectory == "" {
		stateDirectory = DefaultStateDirectory()
	}
	store, err := runtimeidentity.New(stateDirectory)
	if err != nil {
		return "", err
	}
	privateKey, err := store.LoadOrCreateKey()
	if err != nil {
		return "", err
	}
	deviceID, err := runtimeclient.Pair(ctx, options.ServerURL, options.Code, options.DeviceName, privateKey.Public().(ed25519.PublicKey), options.AllowInsecureLoopback)
	if err != nil {
		return "", err
	}
	if err := store.SaveMetadata(options.ServerURL, deviceID); err != nil {
		return "", err
	}
	return deviceID, nil
}

func Identity(stateDirectory string) (serverURL, deviceID string, err error) {
	store, err := runtimeidentity.New(stateDirectory)
	if err != nil {
		return "", "", err
	}
	identity, err := store.Load()
	if err != nil {
		return "", "", err
	}
	return identity.ServerURL, identity.DeviceID, nil
}

func ReadReleaseStatus(stateDirectory string) (ReleaseStatus, error) {
	status := ReleaseStatus{}
	current, err := filepath.EvalSymlinks(filepath.Join(stateDirectory, "current"))
	if err == nil {
		raw, readErr := os.ReadFile(filepath.Join(current, "manifest.json"))
		if readErr != nil {
			return status, fmt.Errorf("读取当前 Runtime Release: %w", readErr)
		}
		manifest, decodeErr := releasecontract.Decode(raw)
		if decodeErr != nil {
			return status, decodeErr
		}
		status.ActiveTag = manifest.Tag
		status.ManifestVersion = manifest.Version
	} else if !errors.Is(err, os.ErrNotExist) {
		return status, fmt.Errorf("解析当前 Runtime Release: %w", err)
	}
	raw, err := os.ReadFile(filepath.Join(stateDirectory, "pending-activation.json"))
	if errors.Is(err, os.ErrNotExist) {
		return status, nil
	}
	if err != nil {
		return status, fmt.Errorf("读取待确认 Runtime Release: %w", err)
	}
	var pending struct {
		TargetTag string `json:"target_tag"`
	}
	if err := json.Unmarshal(raw, &pending); err != nil || strings.TrimSpace(pending.TargetTag) == "" {
		return status, errors.New("待确认 Runtime Release 状态无效")
	}
	status.Pending = true
	status.PendingTag = pending.TargetTag
	return status, nil
}

func FindCosign() (string, error) {
	if explicit := strings.TrimSpace(os.Getenv("COSIGN_BIN")); explicit != "" {
		if info, err := os.Stat(explicit); err == nil && !info.IsDir() {
			return explicit, nil
		}
		return "", fmt.Errorf("COSIGN_BIN 指向的文件不可用: %s", explicit)
	}
	for _, candidate := range []string{"/opt/homebrew/bin/cosign", "/usr/local/bin/cosign"} {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	if candidate, err := exec.LookPath("cosign"); err == nil {
		return candidate, nil
	}
	return "", errors.New("未找到 cosign，无法验证签名 Release")
}

func CheckDesktopUpdate(ctx context.Context, currentTag string) (DesktopUpdateStatus, error) {
	cosign, err := FindCosign()
	if err != nil {
		return DesktopUpdateStatus{}, err
	}
	client, err := openReleaseClient(cosign)
	if err != nil {
		return DesktopUpdateStatus{}, err
	}
	latestTag, err := client.LatestTag(ctx)
	if err != nil {
		return DesktopUpdateStatus{}, err
	}
	release, err := client.Fetch(ctx, latestTag)
	if err != nil {
		return DesktopUpdateStatus{}, err
	}
	if release.Manifest.Version != releasecontract.CurrentVersion {
		return DesktopUpdateStatus{}, errors.New("最新 Release 尚未提供桌面 manifest v2")
	}
	if _, ok := release.Manifest.ArtifactWithFormat("desktop", "darwin", "universal", releasecontract.DesktopDMG); !ok {
		return DesktopUpdateStatus{}, errors.New("最新 Release 缺少 macOS universal DMG")
	}
	currentTag = strings.TrimSpace(currentTag)
	return DesktopUpdateStatus{CurrentTag: currentTag, LatestTag: latestTag, Available: currentTag == "" || currentTag == "dev" || currentTag != latestTag}, nil
}

func DownloadDesktopUpdate(ctx context.Context, tag, destination string) error {
	cosign, err := FindCosign()
	if err != nil {
		return err
	}
	client, err := openReleaseClient(cosign)
	if err != nil {
		return err
	}
	release, err := client.Fetch(ctx, tag)
	if err != nil {
		return err
	}
	artifact, ok := release.Manifest.ArtifactWithFormat("desktop", "darwin", "universal", releasecontract.DesktopDMG)
	if !ok {
		return errors.New("Release 缺少 macOS universal DMG")
	}
	return client.DownloadArtifact(ctx, release, artifact, destination)
}
