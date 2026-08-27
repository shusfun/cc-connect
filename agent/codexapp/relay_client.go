package codexapp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"golang.org/x/term"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"

	"golang.org/x/sys/unix"
)

type rpcResponse struct {
	ID     json.RawMessage `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data,omitempty"`
	} `json:"error,omitempty"`
}

type pendingCall struct {
	result chan rpcResponse
}

type relayClient struct {
	stdin    io.WriteCloser
	stdout   io.ReadCloser
	writeMu  sync.Mutex
	mu       sync.Mutex
	pending  map[string]pendingCall
	closed   chan struct{}
	closeErr error
	closeOne sync.Once
	nextID   atomic.Uint64
}

func newRelayClient(socketPath string) (*relayClient, error) {
	if !term.IsTerminal(int(os.Stdin.Fd())) || !term.IsTerminal(int(os.Stdout.Fd())) {
		return nil, errors.New("codex app bridge: Runtime must be started from an interactive Codex App terminal")
	}
	connection, err := net.Dial("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("codex app bridge: connect Desktop App tools socket: %w", err)
	}
	client := &relayClient{
		stdin: connection, stdout: connection, pending: make(map[string]pendingCall), closed: make(chan struct{}),
	}
	go client.readLoop()
	return client, nil
}

func newRelayClientFromFD(fd int) (*relayClient, error) {
	duplicate, err := unix.Dup(fd)
	if err != nil {
		return nil, fmt.Errorf("codex app bridge: duplicate inherited relay fd: %w", err)
	}
	connection := os.NewFile(uintptr(duplicate), "codex-app-worker-relay")
	client := &relayClient{
		stdin: connection, stdout: connection, pending: make(map[string]pendingCall), closed: make(chan struct{}),
	}
	go client.readLoop()
	return client, nil
}

func (c *relayClient) readLoop() {
	for {
		payload, err := readFrame(c.stdout)
		if err != nil {
			c.shutdown(err)
			return
		}
		var response rpcResponse
		if err := json.Unmarshal(payload, &response); err != nil {
			c.shutdown(fmt.Errorf("codex app bridge: decode JSON-RPC response: %w", err))
			return
		}
		id := strings.Trim(string(response.ID), `"`)
		c.mu.Lock()
		pending, ok := c.pending[id]
		if ok {
			delete(c.pending, id)
		}
		c.mu.Unlock()
		if !ok {
			c.shutdown(fmt.Errorf("codex app bridge: response for unknown JSON-RPC id %q", id))
			return
		}
		pending.result <- response
	}
}

func (c *relayClient) request(ctx context.Context, method string, params any, _ string) (json.RawMessage, error) {
	idValue := c.nextID.Add(1)
	id := fmt.Sprintf("%d", idValue)
	pending := pendingCall{result: make(chan rpcResponse, 1)}
	c.mu.Lock()
	select {
	case <-c.closed:
		err := c.closeErr
		c.mu.Unlock()
		return nil, err
	default:
	}
	c.pending[id] = pending
	c.mu.Unlock()
	request := map[string]any{"jsonrpc": "2.0", "id": idValue, "method": method, "params": params}
	payload, err := json.Marshal(request)
	if err != nil {
		c.removePending(id)
		return nil, err
	}
	c.writeMu.Lock()
	err = writeFrame(c.stdin, payload)
	c.writeMu.Unlock()
	if err != nil {
		c.removePending(id)
		c.shutdown(err)
		return nil, fmt.Errorf("codex app bridge: write request: %w", err)
	}
	select {
	case response := <-pending.result:
		if response.Error != nil {
			return nil, fmt.Errorf("codex app bridge: %s: rpc error %d: %s", method, response.Error.Code, response.Error.Message)
		}
		return response.Result, nil
	case <-ctx.Done():
		c.removePending(id)
		c.cancel(idValue)
		return nil, ctx.Err()
	case <-c.closed:
		return nil, c.closeErr
	}
}

func (c *relayClient) cancel(id uint64) {
	payload, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": "tools/cancel"})
	if err != nil {
		return
	}
	c.writeMu.Lock()
	_ = writeFrame(c.stdin, payload)
	c.writeMu.Unlock()
}

func (c *relayClient) removePending(id string) {
	c.mu.Lock()
	delete(c.pending, id)
	c.mu.Unlock()
}

func (c *relayClient) shutdown(err error) {
	if err == nil {
		err = errors.New("codex app bridge: connection closed")
	}
	c.closeOne.Do(func() {
		c.mu.Lock()
		c.closeErr = err
		c.pending = make(map[string]pendingCall)
		close(c.closed)
		c.mu.Unlock()
	})
}

func (c *relayClient) close() error {
	c.shutdown(errors.New("codex app bridge: connection closed"))
	if c.stdin != nil {
		_ = c.stdin.Close()
	}
	if c.stdout != nil {
		_ = c.stdout.Close()
	}
	return nil
}
