package codexapp

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/BurntSushi/toml"
	"github.com/shusfun/cc-connect/core"
)

type automationFile struct {
	ID                   string `toml:"id"`
	Name                 string `toml:"name"`
	Kind                 string `toml:"kind"`
	Prompt               string `toml:"prompt"`
	RRule                string `toml:"rrule"`
	Status               string `toml:"status"`
	Destination          string `toml:"destination"`
	ExecutionEnvironment string `toml:"execution_environment"`
	ProjectID            string `toml:"project_id"`
	TargetThreadID       string `toml:"target_thread_id"`
	Model                string `toml:"model"`
	ReasoningEffort      string `toml:"reasoning_effort"`
	NotificationPolicy   string `toml:"notification_policy"`
}

func codexHome() (string, error) {
	home := strings.TrimSpace(os.Getenv("CODEX_HOME"))
	if home == "" {
		userHome, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		home = filepath.Join(userHome, ".codex")
	}
	return filepath.Clean(home), nil
}

func (a *Agent) ListAutomations(context.Context) ([]core.AgentAutomation, error) {
	home, err := codexHome()
	if err != nil {
		return nil, fmt.Errorf("codex app: locate automation directory: %w", err)
	}
	directory := filepath.Join(home, "automations")
	entries, err := os.ReadDir(directory)
	if errors.Is(err, os.ErrNotExist) {
		return []core.AgentAutomation{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("codex app: read automation directory: %w", err)
	}
	result := make([]core.AgentAutomation, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		id := entry.Name()
		if !validLocalID(id) {
			continue
		}
		path := filepath.Join(directory, id, "automation.toml")
		info, statErr := os.Lstat(path)
		if errors.Is(statErr, os.ErrNotExist) {
			continue
		}
		if statErr != nil || !info.Mode().IsRegular() || info.Size() > 1<<20 {
			return nil, fmt.Errorf("codex app: invalid automation file %q", id)
		}
		var value automationFile
		if _, decodeErr := toml.DecodeFile(path, &value); decodeErr != nil {
			return nil, fmt.Errorf("codex app: decode automation %q: %w", id, decodeErr)
		}
		if value.ID == "" {
			value.ID = id
		}
		result = append(result, core.AgentAutomation{
			ID: value.ID, Name: value.Name, Kind: value.Kind, Prompt: value.Prompt, RRule: value.RRule,
			Status: value.Status, Destination: value.Destination, ExecutionEnvironment: value.ExecutionEnvironment,
			ProjectID: value.ProjectID, TargetThreadID: value.TargetThreadID, Model: value.Model,
			ReasoningEffort: value.ReasoningEffort, NotificationPolicy: value.NotificationPolicy,
		})
	}
	sort.Slice(result, func(i, j int) bool { return strings.ToLower(result[i].Name) < strings.ToLower(result[j].Name) })
	return result, nil
}

func validLocalID(value string) bool {
	return value != "" && value != "." && value != ".." && !strings.ContainsAny(value, `/\\\x00`)
}

func (a *Agent) CreateAutomation(ctx context.Context, mutation core.AgentAutomationMutation) (core.AgentAutomation, error) {
	mutation.ID = ""
	if err := validateAutomationMutation(mutation, false); err != nil {
		return core.AgentAutomation{}, err
	}
	if _, err := a.callJSON(ctx, "automation_update", automationArguments("create", mutation)); err != nil {
		return core.AgentAutomation{}, err
	}
	return a.findAutomation(ctx, "", mutation.Name)
}

func (a *Agent) UpdateAutomation(ctx context.Context, mutation core.AgentAutomationMutation) (core.AgentAutomation, error) {
	if !validLocalID(mutation.ID) {
		return core.AgentAutomation{}, errors.New("codex app: automation id is invalid")
	}
	current, err := a.findAutomation(ctx, mutation.ID, "")
	if err != nil {
		return core.AgentAutomation{}, err
	}
	mutation = mergeAutomation(current, mutation)
	if err := validateAutomationMutation(mutation, true); err != nil {
		return core.AgentAutomation{}, err
	}
	if _, err := a.callJSON(ctx, "automation_update", automationArguments("update", mutation)); err != nil {
		return core.AgentAutomation{}, err
	}
	return a.findAutomation(ctx, mutation.ID, "")
}

func (a *Agent) DeleteAutomation(ctx context.Context, id string) error {
	if !validLocalID(id) {
		return errors.New("codex app: automation id is invalid")
	}
	if _, err := a.findAutomation(ctx, id, ""); err != nil {
		return err
	}
	_, err := a.callJSON(ctx, "automation_update", map[string]any{"id": id, "mode": "delete"})
	return err
}

func (a *Agent) findAutomation(ctx context.Context, id, name string) (core.AgentAutomation, error) {
	values, err := a.ListAutomations(ctx)
	if err != nil {
		return core.AgentAutomation{}, err
	}
	for _, value := range values {
		if id != "" && value.ID == id || id == "" && value.Name == name {
			return value, nil
		}
	}
	return core.AgentAutomation{}, errors.New("codex app: automation not found")
}

func validateAutomationMutation(value core.AgentAutomationMutation, update bool) error {
	if update && value.ID == "" || strings.TrimSpace(value.Name) == "" || strings.TrimSpace(value.Prompt) == "" || strings.TrimSpace(value.RRule) == "" {
		return errors.New("codex app: automation id, name, prompt, and rrule are required")
	}
	if value.Kind != "heartbeat" && value.Kind != "cron" {
		return errors.New("codex app: automation kind must be heartbeat or cron")
	}
	if value.Status != "ACTIVE" && value.Status != "PAUSED" {
		return errors.New("codex app: automation status must be ACTIVE or PAUSED")
	}
	if value.Kind == "heartbeat" {
		if value.Destination != "thread" || strings.TrimSpace(value.TargetThreadID) == "" {
			return errors.New("codex app: heartbeat automation requires a target thread")
		}
		if value.ExecutionEnvironment != "" || value.ProjectID != "" {
			return errors.New("codex app: heartbeat automation cannot select a project execution environment")
		}
	}
	if value.Kind == "cron" {
		if value.Destination != "local" || value.ExecutionEnvironment != "local" {
			return errors.New("codex app: cron automation requires the local execution environment")
		}
		if value.TargetThreadID != "" {
			return errors.New("codex app: cron automation cannot target a thread")
		}
	}
	return nil
}

func mergeAutomation(current core.AgentAutomation, patch core.AgentAutomationMutation) core.AgentAutomationMutation {
	if patch.Name == "" {
		patch.Name = current.Name
	}
	if patch.Kind == "" {
		patch.Kind = current.Kind
	}
	if patch.Prompt == "" {
		patch.Prompt = current.Prompt
	}
	if patch.RRule == "" {
		patch.RRule = current.RRule
	}
	if patch.Status == "" {
		patch.Status = current.Status
	}
	if patch.Destination == "" {
		patch.Destination = current.Destination
	}
	if patch.ExecutionEnvironment == "" {
		patch.ExecutionEnvironment = current.ExecutionEnvironment
	}
	if patch.ProjectID == "" {
		patch.ProjectID = current.ProjectID
	}
	if patch.TargetThreadID == "" {
		patch.TargetThreadID = current.TargetThreadID
	}
	if patch.Model == "" {
		patch.Model = current.Model
	}
	if patch.ReasoningEffort == "" {
		patch.ReasoningEffort = current.ReasoningEffort
	}
	if patch.NotificationPolicy == "" {
		patch.NotificationPolicy = current.NotificationPolicy
	}
	return patch
}

func automationArguments(mode string, value core.AgentAutomationMutation) map[string]any {
	result := map[string]any{"mode": mode, "kind": value.Kind, "name": value.Name, "prompt": value.Prompt, "rrule": value.RRule, "status": value.Status}
	if value.ID != "" {
		result["id"] = value.ID
	}
	if value.Destination != "" {
		result["destination"] = value.Destination
	}
	if value.ExecutionEnvironment != "" {
		result["executionEnvironment"] = value.ExecutionEnvironment
	}
	if value.ProjectID != "" {
		result["projectId"] = value.ProjectID
	}
	if value.TargetThreadID != "" {
		result["targetThreadId"] = value.TargetThreadID
	}
	if value.Model != "" {
		result["model"] = value.Model
	}
	if value.ReasoningEffort != "" {
		result["reasoningEffort"] = value.ReasoningEffort
	}
	if value.NotificationPolicy != "" {
		result["notificationPolicy"] = value.NotificationPolicy
	}
	return result
}
