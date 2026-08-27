package codexapp

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
	"time"
)

type scriptedBridgeClient struct {
	mu          sync.Mutex
	requestFunc func(context.Context, string, any, string) (json.RawMessage, error)
	closed      bool
}

func (c *scriptedBridgeClient) request(ctx context.Context, method string, params any, callID string) (json.RawMessage, error) {
	return c.requestFunc(ctx, method, params, callID)
}

func (c *scriptedBridgeClient) close() error {
	c.mu.Lock()
	c.closed = true
	c.mu.Unlock()
	return nil
}

func toolsListResult(optional ...string) json.RawMessage {
	names := append([]string{}, requiredTools...)
	names = append(names, optional...)
	tools := make([]ToolDefinition, 0, len(names))
	for _, name := range names {
		tools = append(tools, ToolDefinition{Name: name, Namespace: "codex_app", InputSchema: schema(requiredToolFields[name]...)})
	}
	raw, _ := json.Marshal(map[string]any{"tools": tools})
	return raw
}

func healthyScriptedClient(optional ...string) *scriptedBridgeClient {
	return &scriptedBridgeClient{requestFunc: func(_ context.Context, method string, _ any, _ string) (json.RawMessage, error) {
		if method == "tools/list" {
			return toolsListResult(optional...), nil
		}
		return json.RawMessage(`{"success":true,"contentItems":[]}`), nil
	}}
}

func bridgeOptions(factory func(string) (bridgeRPCClient, error), candidates ...string) BridgeOptions {
	return BridgeOptions{
		ContextThreadID: "context-task",
		newClient:       factory,
		candidates:      func() ([]string, error) { return candidates, nil },
	}
}

func TestBridgeSkipsStaleCandidateAndRejectsMultipleActiveSockets(t *testing.T) {
	stale := &scriptedBridgeClient{requestFunc: func(context.Context, string, any, string) (json.RawMessage, error) {
		return nil, io.EOF
	}}
	healthy := healthyScriptedClient()
	bridge, err := NewBridge(bridgeOptions(func(path string) (bridgeRPCClient, error) {
		if path == "stale.sock" {
			return stale, nil
		}
		return healthy, nil
	}, "stale.sock", "active.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = bridge.Close() }()
	stale.mu.Lock()
	staleClosed := stale.closed
	stale.mu.Unlock()
	if !staleClosed {
		t.Fatal("stale candidate was not closed")
	}

	_, err = NewBridge(bridgeOptions(func(string) (bridgeRPCClient, error) {
		return healthyScriptedClient(), nil
	}, "one.sock", "two.sock"))
	if err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("expected ambiguous active socket error, got %v", err)
	}
}

func TestBridgeReconnectReloadsSchemaAndDoesNotReplayWrites(t *testing.T) {
	var mu sync.Mutex
	created := 0
	factory := func(string) (bridgeRPCClient, error) {
		mu.Lock()
		created++
		generation := created
		mu.Unlock()
		client := healthyScriptedClient()
		if generation == 2 {
			client = healthyScriptedClient("set_thread_title")
		}
		base := client.requestFunc
		client.requestFunc = func(ctx context.Context, method string, params any, callID string) (json.RawMessage, error) {
			if generation == 1 && method == "tools/call" {
				values, _ := params.(map[string]any)
				if values["tool"] == "list_threads" {
					return nil, io.EOF
				}
			}
			return base(ctx, method, params, callID)
		}
		return client, nil
	}
	bridge, err := NewBridge(bridgeOptions(factory, "app.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = bridge.Close() }()
	firstFingerprint := bridge.SchemaFingerprint()
	if bridge.HasTool("set_thread_title") {
		t.Fatal("unexpected optional tool before reconnect")
	}
	if _, err := bridge.Call(t.Context(), "list_threads", map[string]any{}); err != nil {
		t.Fatal(err)
	}
	if !bridge.HasTool("set_thread_title") || bridge.SchemaFingerprint() == firstFingerprint {
		t.Fatal("reconnect did not atomically replace the schema catalog")
	}

	writeFactoryCalls := 0
	writeBridge, err := NewBridge(bridgeOptions(func(string) (bridgeRPCClient, error) {
		writeFactoryCalls++
		client := healthyScriptedClient()
		base := client.requestFunc
		client.requestFunc = func(ctx context.Context, method string, params any, callID string) (json.RawMessage, error) {
			if method == "tools/call" {
				values, _ := params.(map[string]any)
				if values["tool"] == "send_message_to_thread" {
					return nil, io.ErrUnexpectedEOF
				}
			}
			return base(ctx, method, params, callID)
		}
		return client, nil
	}, "app.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = writeBridge.Close() }()
	_, err = writeBridge.Call(t.Context(), "send_message_to_thread", map[string]any{"threadId": "t1", "prompt": "hi"})
	if err == nil || !strings.Contains(err.Error(), "was not replayed") {
		t.Fatalf("expected unknown write outcome error, got %v", err)
	}
	if writeFactoryCalls != 1 {
		t.Fatalf("write was reconnected/replayed, factory calls = %d", writeFactoryCalls)
	}
}

func TestBridgeToolsCallUsesUniqueCallAndTurnIDsAcrossConnections(t *testing.T) {
	var mu sync.Mutex
	callIDs := make(map[string]struct{})
	turnIDs := make(map[string]struct{})
	requestCount := 0
	factory := func(string) (bridgeRPCClient, error) {
		client := healthyScriptedClient()
		base := client.requestFunc
		client.requestFunc = func(ctx context.Context, method string, params any, callID string) (json.RawMessage, error) {
			if method == "tools/call" {
				values, ok := params.(map[string]any)
				if !ok {
					t.Fatalf("tools/call params type = %T", params)
				}
				parameterCallID, _ := values["callId"].(string)
				turnID, _ := values["turnId"].(string)
				if parameterCallID == "" || turnID == "" || callID != parameterCallID {
					t.Fatalf("invalid invocation IDs: params=%#v requestCallID=%q", values, callID)
				}
				mu.Lock()
				defer mu.Unlock()
				if _, exists := callIDs[parameterCallID]; exists {
					t.Fatalf("reused callId %q", parameterCallID)
				}
				if _, exists := turnIDs[turnID]; exists {
					t.Fatalf("reused turnId %q", turnID)
				}
				callIDs[parameterCallID] = struct{}{}
				turnIDs[turnID] = struct{}{}
				requestCount++
			}
			return base(ctx, method, params, callID)
		}
		return client, nil
	}

	for range 2 {
		bridge, err := NewBridge(bridgeOptions(factory, "app.sock"))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := bridge.Call(t.Context(), "list_threads", map[string]any{}); err != nil {
			t.Fatal(err)
		}
		if err := bridge.Close(); err != nil {
			t.Fatal(err)
		}
	}
	if requestCount != 4 {
		t.Fatalf("tools/call requests = %d, want 4", requestCount)
	}
}

func TestLoadCatalogRejectsMissingRequiredCapability(t *testing.T) {
	client := &scriptedBridgeClient{requestFunc: func(context.Context, string, any, string) (json.RawMessage, error) {
		var tools []ToolDefinition
		for _, name := range requiredTools[1:] {
			tools = append(tools, ToolDefinition{Name: name, Namespace: "codex_app", InputSchema: schema(requiredToolFields[name]...)})
		}
		raw, _ := json.Marshal(map[string]any{"tools": tools})
		return raw, nil
	}}
	_, err := loadCatalog(t.Context(), client)
	if err == nil || !strings.Contains(err.Error(), `missing required compatible capability "create_thread"`) {
		t.Fatalf("expected missing capability error, got %v", err)
	}
}

type relayHarness struct {
	client         *relayClient
	requestReader  *io.PipeReader
	responseWriter *io.PipeWriter
}

func newRelayHarness(t *testing.T) *relayHarness {
	t.Helper()
	requestReader, requestWriter := io.Pipe()
	responseReader, responseWriter := io.Pipe()
	client := &relayClient{
		stdin: requestWriter, stdout: responseReader,
		pending: make(map[string]pendingCall), closed: make(chan struct{}),
	}
	go client.readLoop()
	t.Cleanup(func() {
		client.shutdown(errors.New("test complete"))
		_ = requestReader.Close()
		_ = requestWriter.Close()
		_ = responseReader.Close()
		_ = responseWriter.Close()
	})
	return &relayHarness{client: client, requestReader: requestReader, responseWriter: responseWriter}
}

func TestRelayClientCorrelatesConcurrentOutOfOrderResponses(t *testing.T) {
	harness := newRelayHarness(t)
	type request struct {
		ID     uint64         `json:"id"`
		Params map[string]any `json:"params"`
	}
	requests := make([]request, 0, 2)
	serverDone := make(chan error, 1)
	go func() {
		for range 2 {
			frame, err := readFrame(harness.requestReader)
			if err != nil {
				serverDone <- err
				return
			}
			var value request
			if err := json.Unmarshal(frame, &value); err != nil {
				serverDone <- err
				return
			}
			requests = append(requests, value)
		}
		for index := len(requests) - 1; index >= 0; index-- {
			raw, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": requests[index].ID, "result": requests[index].Params})
			if err := writeFrame(harness.responseWriter, raw); err != nil {
				serverDone <- err
				return
			}
		}
		serverDone <- nil
	}()

	results := make(chan string, 2)
	for _, marker := range []string{"first", "second"} {
		marker := marker
		go func() {
			raw, err := harness.client.request(t.Context(), "test", map[string]any{"marker": marker}, "")
			if err != nil {
				results <- "error:" + err.Error()
				return
			}
			var result map[string]string
			_ = json.Unmarshal(raw, &result)
			results <- result["marker"]
		}()
	}
	seen := map[string]bool{<-results: true, <-results: true}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
	if !seen["first"] || !seen["second"] {
		t.Fatalf("responses were not correlated: %#v", seen)
	}
}

func TestRelayClientUnknownIDClosesConnectionAndCancellationSendsFrame(t *testing.T) {
	unknown := newRelayHarness(t)
	raw, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": "missing", "result": map[string]any{}})
	if err := writeFrame(unknown.responseWriter, raw); err != nil {
		t.Fatal(err)
	}
	select {
	case <-unknown.client.closed:
		if !strings.Contains(unknown.client.closeErr.Error(), "unknown JSON-RPC id") {
			t.Fatalf("unexpected close error: %v", unknown.client.closeErr)
		}
	case <-time.After(time.Second):
		t.Fatal("unknown response ID did not close the connection")
	}

	cancelHarness := newRelayHarness(t)
	ctx, cancel := context.WithCancel(t.Context())
	result := make(chan error, 1)
	go func() {
		_, err := cancelHarness.client.request(ctx, "tools/call", map[string]any{}, "call-42")
		result <- err
	}()
	if _, err := readFrame(cancelHarness.requestReader); err != nil {
		t.Fatal(err)
	}
	cancel()
	cancelFrame, err := readFrame(cancelHarness.requestReader)
	if err != nil {
		t.Fatal(err)
	}
	var notification struct {
		Method string `json:"method"`
		ID     uint64 `json:"id"`
	}
	if err := json.Unmarshal(cancelFrame, &notification); err != nil {
		t.Fatal(err)
	}
	if notification.Method != "tools/cancel" || notification.ID == 0 {
		t.Fatalf("unexpected cancel notification: %#v", notification)
	}
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Fatalf("request error = %v, want canceled", err)
	}
}
