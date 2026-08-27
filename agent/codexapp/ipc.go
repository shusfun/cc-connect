package codexapp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func (b *Bridge) contextThread(ctx context.Context) (string, error) {
	if explicit := strings.TrimSpace(firstNonEmpty(b.opts.ContextThreadID, os.Getenv("CODEX_THREAD_ID"))); explicit != "" {
		return explicit, nil
	}
	if b.contextID != "" {
		return b.contextID, nil
	}
	path := strings.TrimSpace(b.opts.IPCSocketPath)
	if path == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("codex app bridge: locate Desktop App IPC socket: %w", err)
		}
		path = filepath.Join(home, ".codex", "ipc", "ipc.sock")
	}
	discoveryCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	threadID, err := discoverContextThread(discoveryCtx, path)
	if err != nil {
		return "", err
	}
	b.contextID = threadID
	return threadID, nil
}

func discoverContextThread(ctx context.Context, socketPath string) (string, error) {
	dialer := net.Dialer{}
	conn, err := dialer.DialContext(ctx, "unix", socketPath)
	if err != nil {
		return "", fmt.Errorf("codex app bridge: connect Desktop App IPC router: %w", err)
	}
	defer func() { _ = conn.Close() }()
	request := map[string]any{
		"type": "request", "requestId": "cc-connect-initialize", "sourceClientId": "initializing-client",
		"version": 0, "method": "initialize", "params": map[string]any{"clientType": "cc-connect-runtime"},
	}
	payload, err := json.Marshal(request)
	if err != nil {
		return "", err
	}
	if err := writeFrame(conn, payload); err != nil {
		return "", fmt.Errorf("codex app bridge: initialize Desktop App IPC router: %w", err)
	}
	for {
		if deadline, ok := ctx.Deadline(); ok {
			_ = conn.SetReadDeadline(deadline)
		}
		frame, err := readFrame(conn)
		if err != nil {
			if ctx.Err() != nil {
				return "", fmt.Errorf("codex app bridge: no routable Desktop App task is currently open: %w", ctx.Err())
			}
			return "", fmt.Errorf("codex app bridge: read Desktop App IPC discovery: %w", err)
		}
		var message struct {
			Type   string `json:"type"`
			Method string `json:"method"`
			Params struct {
				ConversationID string `json:"conversationId"`
				Following      bool   `json:"following"`
			} `json:"params"`
		}
		if err := json.Unmarshal(frame, &message); err != nil {
			return "", fmt.Errorf("codex app bridge: decode Desktop App IPC discovery: %w", err)
		}
		if message.Type == "broadcast" && message.Method == "thread-stream-following-changed" && message.Params.Following && strings.TrimSpace(message.Params.ConversationID) != "" {
			return message.Params.ConversationID, nil
		}
		select {
		case <-ctx.Done():
			return "", errors.New("codex app bridge: no routable Desktop App task is currently open")
		default:
		}
	}
}
