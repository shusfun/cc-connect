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
