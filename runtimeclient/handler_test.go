package runtimeclient

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/shusfun/cc-connect/core"
	"github.com/shusfun/cc-connect/runtimeprotocol"
)

type capabilityAgent struct{}

func (*capabilityAgent) Name() string { return "capability-test" }
func (*capabilityAgent) StartSession(context.Context, string) (core.AgentSession, error) {
	return nil, errors.New("unused")
}
func (*capabilityAgent) ListSessions(context.Context) ([]core.AgentSessionInfo, error) {
	return nil, nil
}
func (*capabilityAgent) ListProjects(context.Context) ([]core.AgentProjectInfo, error) {
	return nil, nil
}
func (*capabilityAgent) ReadSession(context.Context, string, string, string, int) (core.AgentSessionSnapshot, error) {
	return core.AgentSessionSnapshot{}, nil
}
func (*capabilityAgent) ListSessionPage(context.Context, core.AgentSessionListRequest) (core.AgentSessionPage, error) {
	return core.AgentSessionPage{}, nil
}
func (*capabilityAgent) ReadTask(context.Context, string, string, string, int) (core.AgentTaskSnapshot, error) {
	return core.AgentTaskSnapshot{}, nil
}
func (*capabilityAgent) SessionCapabilities(context.Context, string) (core.AgentSessionCapabilities, error) {
	return core.AgentSessionCapabilities{
		Create: core.AgentSessionCapability{Supported: true},
		Pin:    core.AgentSessionCapability{Reason: "当前 App schema 未提供置顶工具"},
	}, nil
}
func (*capabilityAgent) Stop() error { return nil }

type hostTargetSession struct {
	hostID     string
	hostAtSend string
	events     chan core.Event
}

func (s *hostTargetSession) SetHostID(hostID string) { s.hostID = hostID }
func (s *hostTargetSession) Send(string, string, []core.ImageAttachment, []core.FileAttachment) error {
	s.hostAtSend = s.hostID
	s.events <- core.Event{Type: core.EventResult, SessionID: "task-1", Done: true}
	return nil
}
func (*hostTargetSession) RespondPermission(string, core.PermissionResult) error { return nil }
func (s *hostTargetSession) Events() <-chan core.Event                           { return s.events }
func (*hostTargetSession) CurrentSessionID() string                              { return "task-1" }
func (*hostTargetSession) Alive() bool                                           { return true }
func (*hostTargetSession) Close() error                                          { return nil }

type hostTargetAgent struct {
	capabilityAgent
	session *hostTargetSession
}

type productFeatureAgent struct {
	capabilityAgent
	automation core.AgentAutomation
	plugin     core.AgentPlugin
}

func (a *productFeatureAgent) SearchTasks(_ context.Context, request core.AgentTaskSearchRequest) ([]core.AgentTaskSearchResult, error) {
	return []core.AgentTaskSearchResult{{Task: core.AgentSessionInfo{ID: "task-1", ProjectID: "project-1", Summary: request.Query}}}, nil
}
func (*productFeatureAgent) ListArchivedTasks(context.Context, int) (core.AgentSessionPage, error) {
	return core.AgentSessionPage{Sessions: []core.AgentSessionInfo{{ID: "archived-1", Archived: true}}}, nil
}
func (a *productFeatureAgent) ListAutomations(context.Context) ([]core.AgentAutomation, error) {
	return []core.AgentAutomation{a.automation}, nil
}
func (a *productFeatureAgent) CreateAutomation(_ context.Context, mutation core.AgentAutomationMutation) (core.AgentAutomation, error) {
	a.automation = core.AgentAutomation{ID: "automation-1", Name: mutation.Name, Status: mutation.Status}
	return a.automation, nil
}
func (a *productFeatureAgent) UpdateAutomation(_ context.Context, mutation core.AgentAutomationMutation) (core.AgentAutomation, error) {
	a.automation.Name, a.automation.Status = mutation.Name, mutation.Status
	return a.automation, nil
}
func (a *productFeatureAgent) DeleteAutomation(context.Context, string) error {
	a.automation = core.AgentAutomation{}
	return nil
}
func (a *productFeatureAgent) ListPlugins(context.Context, bool) ([]core.AgentPlugin, error) {
	return []core.AgentPlugin{a.plugin}, nil
}
func (a *productFeatureAgent) InstallPlugin(_ context.Context, id string) (core.AgentPlugin, error) {
	a.plugin = core.AgentPlugin{ID: id, Name: "Demo", Marketplace: "Official", Installed: true}
	return a.plugin, nil
}
func (a *productFeatureAgent) RemovePlugin(context.Context, string) error {
	a.plugin.Installed = false
	return nil
}

func (a *hostTargetAgent) StartSession(context.Context, string) (core.AgentSession, error) {
	return a.session, nil
}

func TestHandlerReturnsAuditedTaskCapabilities(t *testing.T) {
	handler, err := NewHandler(Dependencies{Agent: &capabilityAgent{}})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := handler.Handle(t.Context(), runtimeprotocol.MethodCapabilityList, runtimeprotocol.Resource{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	var capabilities core.AgentSessionCapabilities
	if err := json.Unmarshal(raw, &capabilities); err != nil {
		t.Fatal(err)
	}
	if !capabilities.Create.Supported || capabilities.Pin.Supported || capabilities.Pin.Reason == "" {
		t.Fatalf("unexpected capabilities: %#v", capabilities)
	}
}

func TestHandlerSendSetsNativeTaskHostBeforeSending(t *testing.T) {
	session := &hostTargetSession{events: make(chan core.Event, 1)}
	handler, err := NewHandler(Dependencies{Agent: &hostTargetAgent{session: session}})
	if err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(runtimeprotocol.TaskSendRequest{
		TaskRef: runtimeprotocol.TaskRef{TaskID: "task-1", HostID: "local"},
		Prompt:  "hello",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := handler.Handle(t.Context(), runtimeprotocol.MethodTaskSend, runtimeprotocol.Resource{}, payload); err != nil {
		t.Fatal(err)
	}
	if session.hostAtSend != "local" {
		t.Fatalf("host at Send = %q, want local", session.hostAtSend)
	}
}

func TestHandlerRoutesCodexProductFeaturesThroughTypedInterfaces(t *testing.T) {
	agent := &productFeatureAgent{plugin: core.AgentPlugin{ID: "demo@official", Name: "Demo", Marketplace: "Official"}}
	handler, err := NewHandler(Dependencies{Agent: agent})
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		method  runtimeprotocol.Method
		payload any
		want    string
	}{
		{runtimeprotocol.MethodTaskSearch, runtimeprotocol.TaskSearchRequest{Query: "needle", Limit: 10}, `"summary":"needle"`},
		{runtimeprotocol.MethodTaskArchived, runtimeprotocol.TaskListRequest{Limit: 10}, `"archived":true`},
		{runtimeprotocol.MethodAutomationCreate, core.AgentAutomationMutation{Name: "Daily", Kind: "cron", Status: "ACTIVE"}, `"id":"automation-1"`},
		{runtimeprotocol.MethodPluginInstall, runtimeprotocol.PluginMutationRequest{ID: "demo@official"}, `"installed":true`},
	}
	for _, test := range tests {
		raw, marshalErr := json.Marshal(test.payload)
		if marshalErr != nil {
			t.Fatal(marshalErr)
		}
		result, handleErr := handler.Handle(context.Background(), test.method, runtimeprotocol.Resource{}, raw)
		if handleErr != nil || !strings.Contains(string(result), test.want) {
			t.Fatalf("Handle(%s) = %s, %v", test.method, result, handleErr)
		}
	}
}
