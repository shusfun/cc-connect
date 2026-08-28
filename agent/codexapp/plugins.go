package codexapp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/shusfun/cc-connect/core"
)

type pluginCommandResult struct {
	Installed []pluginJSON `json:"installed"`
	Available []pluginJSON `json:"available"`
}

type pluginJSON struct {
	ID                string          `json:"pluginId"`
	Name              string          `json:"name"`
	Marketplace       string          `json:"marketplaceName"`
	Version           string          `json:"version"`
	Installed         bool            `json:"installed"`
	Enabled           bool            `json:"enabled"`
	InstallPolicy     string          `json:"installPolicy"`
	AuthPolicy        string          `json:"authPolicy"`
	Source            json.RawMessage `json:"source"`
	MarketplaceSource json.RawMessage `json:"marketplaceSource"`
}

func (a *Agent) ListPlugins(ctx context.Context, available bool) ([]core.AgentPlugin, error) {
	args := []string{"plugin", "list", "--json"}
	if available {
		args = append(args, "--available")
	}
	raw, err := runCodexPlugin(ctx, args...)
	if err != nil {
		return nil, err
	}
	var response pluginCommandResult
	if err := strictPluginJSON(raw, &response); err != nil {
		return nil, fmt.Errorf("codex app: decode plugin catalog: %w", err)
	}
	values := append(response.Installed, response.Available...)
	result := make([]core.AgentPlugin, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		if value.ID == "" || value.Name == "" || value.Marketplace == "" {
			return nil, errors.New("codex app: plugin catalog contains an invalid entry")
		}
		if _, exists := seen[value.ID]; exists {
			continue
		}
		seen[value.ID] = struct{}{}
		result = append(result, core.AgentPlugin{ID: value.ID, Name: value.Name, Marketplace: value.Marketplace, Version: value.Version, Installed: value.Installed, Enabled: value.Enabled, InstallPolicy: value.InstallPolicy, AuthPolicy: value.AuthPolicy})
	}
	return result, nil
}

func (a *Agent) InstallPlugin(ctx context.Context, id string) (core.AgentPlugin, error) {
	plugin, err := a.findPlugin(ctx, id, false)
	if err != nil {
		return core.AgentPlugin{}, err
	}
	if plugin.Installed {
		return plugin, nil
	}
	if _, err := runCodexPlugin(ctx, "plugin", "add", id, "--json"); err != nil {
		return core.AgentPlugin{}, err
	}
	return a.findPlugin(ctx, id, true)
}

func (a *Agent) RemovePlugin(ctx context.Context, id string) error {
	plugin, err := a.findPlugin(ctx, id, false)
	if err != nil {
		return err
	}
	if !plugin.Installed {
		return errors.New("codex app: plugin is not installed")
	}
	_, err = runCodexPlugin(ctx, "plugin", "remove", id, "--json")
	return err
}

func (a *Agent) findPlugin(ctx context.Context, id string, installedOnly bool) (core.AgentPlugin, error) {
	if id == "" || strings.ContainsAny(id, " /\\\x00") || strings.Count(id, "@") != 1 {
		return core.AgentPlugin{}, errors.New("codex app: plugin id is invalid")
	}
	values, err := a.ListPlugins(ctx, !installedOnly)
	if err != nil {
		return core.AgentPlugin{}, err
	}
	for _, value := range values {
		if value.ID == id && (!installedOnly || value.Installed) {
			return value, nil
		}
	}
	return core.AgentPlugin{}, errors.New("codex app: plugin not found in the current catalog")
}

func runCodexPlugin(ctx context.Context, args ...string) ([]byte, error) {
	path, err := exec.LookPath("codex")
	if err != nil {
		return nil, errors.New("codex app: official codex plugin manager is unavailable")
	}
	path, err = filepath.EvalSymlinks(path)
	if err != nil {
		return nil, fmt.Errorf("codex app: resolve codex plugin manager: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&0o111 == 0 {
		return nil, errors.New("codex app: codex plugin manager executable is invalid")
	}
	command := exec.CommandContext(ctx, path, args...)
	var stdout, stderr bytes.Buffer
	command.Stdout = &limitedWriter{writer: &stdout, remaining: 4 << 20}
	command.Stderr = &limitedWriter{writer: &stderr, remaining: 64 << 10}
	if err := command.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return nil, fmt.Errorf("codex app: plugin command failed: %s", redactPluginError(message))
	}
	return stdout.Bytes(), nil
}

var pluginSecretPattern = regexp.MustCompile(`(?i)(authorization|password|secret|token)([[:space:]]*[:=][[:space:]]*)[^[:space:],;]+`)

func redactPluginError(message string) string {
	return pluginSecretPattern.ReplaceAllString(message, "$1$2[REDACTED]")
}

type limitedWriter struct {
	writer    io.Writer
	remaining int64
}

func (w *limitedWriter) Write(value []byte) (int, error) {
	if int64(len(value)) > w.remaining {
		return 0, errors.New("command output limit exceeded")
	}
	n, err := w.writer.Write(value)
	w.remaining -= int64(n)
	return n, err
}

func strictPluginJSON(raw []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("plugin response contains trailing JSON")
	}
	return nil
}
