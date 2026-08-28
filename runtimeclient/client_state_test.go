package runtimeclient

import "testing"

func TestConnectionStateCallbackPreservesGenerationAndDisconnect(t *testing.T) {
	var states []ConnectionState
	client := &Client{config: ClientConfig{OnConnectionState: func(state ConnectionState) {
		states = append(states, state)
	}}}
	client.reportConnectionState(ConnectionState{Connected: true, ConnectionGeneration: 9})
	client.reportConnectionState(ConnectionState{})

	if len(states) != 2 {
		t.Fatalf("connection states = %#v", states)
	}
	if !states[0].Connected || states[0].ConnectionGeneration != 9 {
		t.Fatalf("connected state = %#v", states[0])
	}
	if states[1].Connected || states[1].ConnectionGeneration != 0 {
		t.Fatalf("disconnect state = %#v", states[1])
	}
}
