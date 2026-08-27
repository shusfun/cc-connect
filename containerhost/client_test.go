package containerhost

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClientPrepareUsesLongerTimeoutThanControlRequests(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "cc-host-client-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	socketPath := filepath.Join(directory, "host.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		time.Sleep(30 * time.Millisecond)
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"ok":false,"error":"server response reached"}`)
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() {
		_ = server.Shutdown(context.Background())
	})

	client, err := newClient(socketPath, 10*time.Millisecond, 100*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Status(t.Context()); err == nil || !strings.Contains(err.Error(), "Client.Timeout exceeded") {
		t.Fatalf("Status() error = %v, want regular request timeout", err)
	}
	if _, _, err := client.Prepare(t.Context(), "v0.2.18"); err == nil || err.Error() != "server response reached" {
		t.Fatalf("Prepare() error = %v, want response through longer prepare timeout", err)
	}
}
