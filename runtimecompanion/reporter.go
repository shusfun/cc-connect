package runtimecompanion

import (
	"encoding/json"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"
)

const StatusFDEnvironment = "CC_CONNECT_RUNTIME_STATUS_FD"

type WorkerConnectionState struct {
	Connected            bool   `json:"connected"`
	ConnectionGeneration uint64 `json:"connection_generation,omitempty"`
}

type Reporter struct {
	mu     sync.Mutex
	writer io.WriteCloser
}

func ReporterFromEnvironment() (*Reporter, error) {
	value := strings.TrimSpace(os.Getenv(StatusFDEnvironment))
	if value == "" {
		return &Reporter{}, nil
	}
	fd, err := strconv.Atoi(value)
	if err != nil || fd < 3 {
		return nil, &os.PathError{Op: "parse status fd", Path: value, Err: os.ErrInvalid}
	}
	return &Reporter{writer: os.NewFile(uintptr(fd), "runtime-status")}, nil
}

func (r *Reporter) Report(state WorkerConnectionState) error {
	if r == nil || r.writer == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return json.NewEncoder(r.writer).Encode(state)
}

func (r *Reporter) Close() error {
	if r == nil || r.writer == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	err := r.writer.Close()
	r.writer = nil
	return err
}
