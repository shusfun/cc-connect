//go:build darwin

package main

import (
	"context"
	"embed"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/shusfun/cc-connect/runtimecompanion"
	"github.com/wailsapp/wails/v3/pkg/application"
	"github.com/wailsapp/wails/v3/pkg/events"
	"github.com/wailsapp/wails/v3/pkg/icons"
)

//go:embed assets/*
var assets embed.FS

var version = "dev"

var singleInstanceKey = [32]byte{
	0x43, 0x43, 0x2d, 0x43, 0x4f, 0x4e, 0x4e, 0x45,
	0x43, 0x54, 0x2d, 0x44, 0x45, 0x53, 0x4b, 0x54,
	0x4f, 0x50, 0x2d, 0x53, 0x49, 0x4e, 0x47, 0x4c,
	0x45, 0x2d, 0x49, 0x4e, 0x53, 0x54, 0x41, 0x4e,
}

type CompanionService struct {
	app            *application.App
	stateDirectory string
}

type DesktopStatus struct {
	Online         bool                              `json:"online"`
	Supervisor     runtimecompanion.SupervisorStatus `json:"supervisor"`
	ControlURL     string                            `json:"control_url,omitempty"`
	DeviceID       string                            `json:"device_id,omitempty"`
	Release        runtimecompanion.ReleaseStatus    `json:"release"`
	Autostart      bool                              `json:"autostart"`
	LogPath        string                            `json:"log_path"`
	DesktopVersion string                            `json:"desktop_version"`
	StatusMessage  string                            `json:"status_message,omitempty"`
	AutostartError string                            `json:"autostart_error,omitempty"`
	ReleaseError   string                            `json:"release_error,omitempty"`
}

func (s *CompanionService) Status() DesktopStatus {
	result := DesktopStatus{
		LogPath: runtimecompanion.RuntimeLogPath(s.stateDirectory), DesktopVersion: version,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := runtimecompanion.QueryStatus(ctx, s.stateDirectory)
	if err == nil {
		result.Online = true
		result.Supervisor = status
		result.ControlURL = status.ControlURL
		result.DeviceID = status.DeviceID
	} else {
		result.StatusMessage = err.Error()
		serverURL, deviceID, identityErr := runtimecompanion.Identity(s.stateDirectory)
		if identityErr == nil {
			result.ControlURL, result.DeviceID = serverURL, deviceID
		}
	}
	result.Release, err = runtimecompanion.ReadReleaseStatus(s.stateDirectory)
	if err != nil {
		result.ReleaseError = err.Error()
	}
	result.Autostart, err = s.app.Autostart.IsEnabled()
	if err != nil {
		result.AutostartError = err.Error()
	}
	return result
}

func (s *CompanionService) Pair(serverURL, code, deviceName string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return runtimecompanion.Pair(ctx, runtimecompanion.PairOptions{
		StateDirectory: s.stateDirectory,
		ServerURL:      strings.TrimSpace(serverURL),
		Code:           strings.TrimSpace(code),
		DeviceName:     strings.TrimSpace(deviceName),
	})
}

func (s *CompanionService) Reconnect() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return runtimecompanion.Reconnect(ctx, s.stateDirectory)
}

func (s *CompanionService) OpenConsole() error {
	serverURL, _, err := runtimecompanion.Identity(s.stateDirectory)
	if err != nil {
		return errors.New("Runtime 尚未配对")
	}
	return s.app.Browser.OpenURL(serverURL)
}

func (s *CompanionService) OpenLogs() error {
	path := runtimecompanion.RuntimeLogPath(s.stateDirectory)
	if _, err := os.Stat(path); err != nil {
		return err
	}
	return s.app.Env.OpenFileManager(path, true)
}

func (s *CompanionService) SetAutostart(enabled bool) error {
	if enabled {
		return s.app.Autostart.Enable()
	}
	return s.app.Autostart.Disable()
}

func (s *CompanionService) CheckUpdate() (runtimecompanion.DesktopUpdateStatus, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	return runtimecompanion.CheckDesktopUpdate(ctx, version)
}

func (s *CompanionService) DownloadUpdate(tag string) (string, error) {
	downloads, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	directory := filepath.Join(downloads, "Downloads")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return "", err
	}
	file, err := os.CreateTemp(directory, ".cc-connect-update-*.dmg")
	if err != nil {
		return "", err
	}
	destination := file.Name()
	if err := file.Close(); err != nil {
		return "", err
	}
	if err := os.Remove(destination); err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	if err := runtimecompanion.DownloadDesktopUpdate(ctx, strings.TrimSpace(tag), destination); err != nil {
		return "", err
	}
	if err := s.app.Browser.OpenFile(destination); err != nil {
		return "", err
	}
	return destination, nil
}

func main() {
	stateDirectory := runtimecompanion.DefaultStateDirectory()
	var window *application.WebviewWindow
	app := application.New(application.Options{
		Name:        "CC-Connect",
		Description: "Codex Desktop App 远程伴生控制器",
		Assets: application.AssetOptions{
			Handler: application.BundledAssetFileServer(assets),
		},
		Mac: application.MacOptions{
			ActivationPolicy: application.ActivationPolicyAccessory,
		},
		SingleInstance: &application.SingleInstanceOptions{
			UniqueID:      "dev.cc-connect.desktop",
			EncryptionKey: singleInstanceKey,
			OnSecondInstanceLaunch: func(application.SecondInstanceData) {
				if window != nil {
					window.Show().Focus()
				}
			},
		},
	})
	service := &CompanionService{app: app, stateDirectory: stateDirectory}
	app.RegisterService(application.NewService(service))
	window = app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:           "CC-Connect 状态",
		Name:            "status",
		URL:             "/",
		Width:           392,
		Height:          540,
		MinWidth:        360,
		MinHeight:       480,
		Hidden:          true,
		Frameless:       true,
		AlwaysOnTop:     true,
		HideOnEscape:    true,
		HideOnFocusLost: true,
	})
	window.RegisterHook(events.Common.WindowClosing, func(event *application.WindowEvent) {
		window.Hide()
		event.Cancel()
	})

	tray := app.SystemTray.New()
	tray.SetTemplateIcon(icons.SystrayMacTemplate)
	tray.SetTooltip("CC-Connect")
	menu := app.NewMenu()
	statusItem := menu.Add("正在读取 Runtime 状态...").SetEnabled(false)
	menu.AddSeparator()
	menu.Add("打开控制台").OnClick(func(*application.Context) {
		if err := service.OpenConsole(); err != nil {
			window.Show().Focus()
		}
	})
	menu.Add("显示状态窗口").OnClick(func(*application.Context) { tray.ShowWindow() })
	menu.Add("从 Codex 终端恢复连接").OnClick(func(*application.Context) {
		if err := service.Reconnect(); err != nil {
			window.Show().Focus()
		}
	})
	menu.Add("查看日志").OnClick(func(*application.Context) {
		if err := service.OpenLogs(); err != nil {
			window.Show().Focus()
		}
	})
	menu.Add("检查更新").OnClick(func(*application.Context) {
		window.Show().Focus()
		window.EmitEvent("check-updates")
	})
	menu.AddSeparator()
	autostart, _ := app.Autostart.IsEnabled()
	autostartItem := menu.AddCheckbox("登录时启动", autostart)
	autostartItem.OnClick(func(ctx *application.Context) {
		enabled := ctx.ClickedMenuItem().Checked()
		if err := service.SetAutostart(enabled); err != nil {
			ctx.ClickedMenuItem().SetChecked(!enabled)
			window.Show().Focus()
		}
	})
	menu.Add("退出").OnClick(func(*application.Context) { app.Quit() })
	tray.SetMenu(menu)
	tray.AttachWindow(window).WindowOffset(4)

	go pollTrayStatus(app.Context(), service, tray, statusItem, window)
	if err := app.Run(); err != nil {
		slog.Error("CC-Connect Desktop 启动失败", "error", err)
		os.Exit(1)
	}
}

func pollTrayStatus(ctx context.Context, service *CompanionService, tray *application.SystemTray, item *application.MenuItem, window *application.WebviewWindow) {
	refresh := func() {
		status := service.Status()
		label := "Runtime 离线"
		if status.Online && status.Supervisor.RuntimeConnected {
			label = "Runtime 已连接"
		} else if status.Online && status.Supervisor.WorkerRunning {
			label = "Runtime 正在连接"
		}
		item.SetLabel(label)
		tray.SetTooltip("CC-Connect - " + label)
		window.EmitEvent("runtime-status", status)
	}
	refresh()
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			refresh()
		}
	}
}
