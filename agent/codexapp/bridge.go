package codexapp

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var requiredTools = []string{
	"create_thread", "list_projects", "list_threads", "read_thread", "send_message_to_thread", "wait_threads",
}

var auditedTools = map[string]struct{}{
	"create_thread": {}, "list_projects": {}, "list_threads": {}, "read_thread": {},
	"send_message_to_thread": {}, "wait_threads": {}, "set_thread_title": {},
	"set_thread_pinned": {}, "set_thread_archived": {}, "fork_thread": {}, "handoff_thread": {},
}

var requiredToolFields = map[string][]string{
	"create_thread":          {"prompt", "target"},
	"list_projects":          {},
	"list_threads":           {},
	"read_thread":            {"threadId"},
	"send_message_to_thread": {"threadId", "prompt"},
	"wait_threads":           {"targets"},
	"set_thread_title":       {"threadId", "title"},
	"set_thread_pinned":      {"threadId", "pinned"},
	"set_thread_archived":    {"threadId", "archived"},
	"fork_thread":            {},
	"handoff_thread":         {"threadId"},
}

var replaySafeTools = map[string]struct{}{
	"list_projects": {}, "list_threads": {}, "read_thread": {}, "wait_threads": {},
	"set_thread_title": {}, "set_thread_pinned": {}, "set_thread_archived": {},
}

type ToolDefinition struct {
	Name        string          `json:"name"`
	Namespace   string          `json:"namespace"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

type toolCatalog struct {
	byName      map[string]ToolDefinition
	fingerprint string
}

type bridgeRPCClient interface {
	request(ctx context.Context, method string, params any, callID string) (json.RawMessage, error)
	close() error
}

type BridgeOptions struct {
	SocketPath      string
	NodePath        string
	ContextThreadID string
	IPCSocketPath   string
	InheritedFD     int
	newClient       func(string) (bridgeRPCClient, error)
	candidates      func() ([]string, error)
}

type Bridge struct {
	opts      BridgeOptions
	mu        sync.Mutex
	client    bridgeRPCClient
	contextID string
	catalog   atomic.Pointer[toolCatalog]
	closed    bool
	nextCall  atomic.Uint64
}

func NewBridge(options BridgeOptions) (*Bridge, error) {
	b := &Bridge{opts: options}
	if err := b.connect(context.Background()); err != nil {
		return nil, err
	}
	return b, nil
}

func (b *Bridge) SchemaFingerprint() string {
	if catalog := b.catalog.Load(); catalog != nil {
		return catalog.fingerprint
	}
	return ""
}

func (b *Bridge) HasTool(name string) bool {
	catalog := b.catalog.Load()
	if catalog == nil {
		return false
	}
	_, ok := catalog.byName[name]
	return ok
}

func (b *Bridge) Call(ctx context.Context, tool string, arguments any) (json.RawMessage, error) {
	if _, ok := auditedTools[tool]; !ok {
		return nil, fmt.Errorf("codex app bridge: tool %q is not in the audited capability allowlist", tool)
	}
	for attempt := 0; attempt < 2; attempt++ {
		client, definition, threadID, err := b.ready(ctx, tool)
		if err != nil {
			return nil, err
		}
		callID, turnID, err := b.nextInvocationIDs()
		if err != nil {
			return nil, err
		}
		result, err := client.request(ctx, "tools/call", map[string]any{
			"arguments": arguments, "callId": callID, "namespace": definition.Namespace,
			"threadId": threadID, "tool": definition.Name, "turnId": turnID,
		}, callID)
		if err == nil || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return result, err
		}
		b.invalidate(client)
		if _, replaySafe := replaySafeTools[tool]; !replaySafe {
			return nil, fmt.Errorf("codex app bridge: %s connection failed after dispatch; outcome is unknown and the write was not replayed: %w", tool, err)
		}
	}
	return nil, errors.New("codex app bridge: App connection unavailable after reconnect")
}

func (b *Bridge) ready(ctx context.Context, tool string) (bridgeRPCClient, ToolDefinition, string, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return nil, ToolDefinition{}, "", errors.New("codex app bridge: closed")
	}
	if b.client == nil {
		if err := b.connectLocked(ctx); err != nil {
			return nil, ToolDefinition{}, "", err
		}
	}
	catalog := b.catalog.Load()
	definition, ok := catalog.byName[tool]
	if !ok {
		return nil, ToolDefinition{}, "", fmt.Errorf("codex app bridge: Desktop App does not provide compatible capability %q", tool)
	}
	threadID, err := b.contextThread(ctx)
	if err != nil {
		return nil, ToolDefinition{}, "", err
	}
	return b.client, definition, threadID, nil
}

func (b *Bridge) connect(ctx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.connectLocked(ctx)
}

func (b *Bridge) connectLocked(ctx context.Context) error {
	if b.closed {
		return errors.New("codex app bridge: closed")
	}
	threadID, err := b.contextThread(ctx)
	if err != nil {
		return err
	}
	newClient := b.opts.newClient
	sockets := []string{"inherited App relay"}
	if b.opts.InheritedFD == 0 {
		var err error
		sockets, err = b.socketCandidates()
		if err != nil {
			return err
		}
	}
	if newClient == nil {
		if b.opts.InheritedFD > 0 {
			newClient = func(string) (bridgeRPCClient, error) { return newRelayClientFromFD(b.opts.InheritedFD) }
		} else {
			newClient = func(socketPath string) (bridgeRPCClient, error) { return newRelayClient(socketPath) }
		}
	}
	type candidate struct {
		client  bridgeRPCClient
		catalog *toolCatalog
		path    string
	}
	valid := make([]candidate, 0, 1)
	failures := make([]string, 0, len(sockets))
	for _, socketPath := range sockets {
		client, startErr := newClient(socketPath)
		if startErr != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", socketPath, startErr))
			continue
		}
		probeCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		catalog, probeErr := loadCatalog(probeCtx, client)
		if probeErr == nil {
			_, probeErr = callToolRaw(probeCtx, client, catalog, threadID, "list_projects", map[string]any{})
		}
		cancel()
		if probeErr != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", socketPath, probeErr))
			_ = client.close()
			continue
		}
		valid = append(valid, candidate{client: client, catalog: catalog, path: socketPath})
	}
	if len(valid) == 0 {
		if len(failures) == 0 {
			return errors.New("codex app bridge: no active Desktop App tools socket accepted the current App task")
		}
		return fmt.Errorf("codex app bridge: no active Desktop App tools socket accepted the current App task: %s", strings.Join(failures, "; "))
	}
	if len(valid) > 1 {
		for _, item := range valid {
			_ = item.client.close()
		}
		paths := make([]string, 0, len(valid))
		for _, item := range valid {
			paths = append(paths, item.path)
		}
		return fmt.Errorf("codex app bridge: multiple active Desktop App tools sockets are ambiguous: %s", strings.Join(paths, ", "))
	}
	b.client = valid[0].client
	b.contextID = threadID
	b.catalog.Store(valid[0].catalog)
	return nil
}

func loadCatalog(ctx context.Context, client bridgeRPCClient) (*toolCatalog, error) {
	result, err := client.request(ctx, "tools/list", map[string]any{"threadStartKind": "all"}, "")
	if err != nil {
		return nil, err
	}
	var envelope struct {
		Tools []ToolDefinition `json:"tools"`
	}
	if err := json.Unmarshal(result, &envelope); err != nil {
		return nil, fmt.Errorf("codex app bridge: decode tools/list: %w", err)
	}
	byName := make(map[string]ToolDefinition)
	canonical := make([]string, 0, len(envelope.Tools))
	for _, tool := range envelope.Tools {
		if _, allowed := auditedTools[tool.Name]; !allowed {
			continue
		}
		if strings.TrimSpace(tool.Namespace) == "" || len(tool.InputSchema) == 0 || !compatibleToolSchema(tool.Name, tool.InputSchema) {
			continue
		}
		byName[tool.Name] = tool
		canonical = append(canonical, tool.Name+"\x00"+tool.Namespace+"\x00"+string(tool.InputSchema))
	}
	for _, name := range requiredTools {
		if _, ok := byName[name]; !ok {
			return nil, fmt.Errorf("codex app bridge: Desktop App is missing required compatible capability %q", name)
		}
	}
	sort.Strings(canonical)
	sum := sha256.Sum256([]byte(strings.Join(canonical, "\n")))
	return &toolCatalog{byName: byName, fingerprint: hex.EncodeToString(sum[:])}, nil
}

func compatibleToolSchema(name string, raw json.RawMessage) bool {
	requiredFields, known := requiredToolFields[name]
	if !known {
		return true
	}
	var schema struct {
		Type                 string                     `json:"type"`
		AdditionalProperties *bool                      `json:"additionalProperties"`
		Properties           map[string]json.RawMessage `json:"properties"`
		Required             []string                   `json:"required"`
	}
	if json.Unmarshal(raw, &schema) != nil || schema.Type != "object" || schema.AdditionalProperties == nil || *schema.AdditionalProperties {
		return false
	}
	required := make(map[string]struct{}, len(schema.Required))
	for _, field := range schema.Required {
		required[field] = struct{}{}
	}
	for _, field := range requiredFields {
		if _, exists := schema.Properties[field]; !exists {
			return false
		}
		if _, exists := required[field]; !exists {
			return false
		}
	}
	return true
}

func callToolRaw(ctx context.Context, client bridgeRPCClient, catalog *toolCatalog, threadID, name string, arguments any) (json.RawMessage, error) {
	tool, ok := catalog.byName[name]
	if !ok {
		return nil, fmt.Errorf("missing tool %s", name)
	}
	callID, err := randomInvocationID("cc-probe-" + name)
	if err != nil {
		return nil, err
	}
	turnID, err := randomInvocationID("cc-turn")
	if err != nil {
		return nil, err
	}
	return client.request(ctx, "tools/call", map[string]any{
		"arguments": arguments, "callId": callID, "namespace": tool.Namespace,
		"threadId": threadID, "tool": name, "turnId": turnID,
	}, callID)
}

func (b *Bridge) nextInvocationIDs() (string, string, error) {
	sequence := b.nextCall.Add(1)
	callID, err := randomInvocationID(fmt.Sprintf("cc-tool-%d", sequence))
	if err != nil {
		return "", "", err
	}
	turnID, err := randomInvocationID("cc-turn")
	if err != nil {
		return "", "", err
	}
	return callID, turnID, nil
}

func randomInvocationID(prefix string) (string, error) {
	var entropy [16]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return "", fmt.Errorf("codex app bridge: create unique invocation ID: %w", err)
	}
	return prefix + "-" + hex.EncodeToString(entropy[:]), nil
}

func (b *Bridge) invalidate(client bridgeRPCClient) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.client == client {
		b.client = nil
		b.contextID = ""
		b.catalog.Store(nil)
		_ = client.close()
	}
}

func (b *Bridge) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.closed = true
	if b.client == nil {
		return nil
	}
	client := b.client
	b.client = nil
	b.contextID = ""
	b.catalog.Store(nil)
	return client.close()
}

func (b *Bridge) nodePath() (string, error) {
	paths := []string{strings.TrimSpace(b.opts.NodePath), strings.TrimSpace(os.Getenv("CODEX_APP_NODE_PATH")),
		"/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node", "/Applications/Codex.app/Contents/Resources/cua_node/bin/node"}
	for _, path := range paths {
		if path != "" {
			if info, err := os.Stat(path); err == nil && !info.IsDir() {
				return path, nil
			}
		}
	}
	return "", errors.New("codex app bridge: signed Desktop App Node runtime was not found")
}

func (b *Bridge) socketCandidates() ([]string, error) {
	if b.opts.candidates != nil {
		return b.opts.candidates()
	}
	if explicit := strings.TrimSpace(firstNonEmpty(b.opts.SocketPath, os.Getenv("CODEX_APP_TOOLS_PIPE_PATH"))); explicit != "" {
		if err := validateOwnedSocket(explicit); err != nil {
			return nil, err
		}
		return []string{explicit}, nil
	}
	paths, err := filepath.Glob("/tmp/codex-browser-use/*.sock")
	if err != nil {
		return nil, err
	}
	result := make([]string, 0, len(paths))
	for _, path := range paths {
		if validateOwnedSocket(path) == nil {
			result = append(result, path)
		}
	}
	if len(result) == 0 {
		return nil, errors.New("codex app bridge: no current-UID Desktop App tools socket found")
	}
	sort.Strings(result)
	return result, nil
}

func validateOwnedSocket(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("codex app bridge: inspect socket %q: %w", path, err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("codex app bridge: %q is not a Unix socket", path)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("codex app bridge: socket %q is not owned by current UID", path)
	}
	return nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
