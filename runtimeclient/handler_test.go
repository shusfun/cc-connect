package runtimeclient

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/chenhg5/cc-connect/core"
	"github.com/chenhg5/cc-connect/runtimeprotocol"
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
