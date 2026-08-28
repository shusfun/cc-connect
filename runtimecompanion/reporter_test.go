package runtimecompanion

import (
	"encoding/json"
	"os"
	"strconv"
	"syscall"
	"testing"
)

func TestReporterFromEnvironmentWritesConnectionGeneration(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reader.Close() })
	fd, err := syscall.Dup(int(writer.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	t.Setenv(StatusFDEnvironment, strconv.Itoa(fd))

	reporter, err := ReporterFromEnvironment()
	if err != nil {
		t.Fatal(err)
	}
	want := WorkerConnectionState{Connected: true, ConnectionGeneration: 17}
	if err := reporter.Report(want); err != nil {
		t.Fatal(err)
	}
	if err := reporter.Close(); err != nil {
		t.Fatal(err)
	}
	var got WorkerConnectionState
	if err := json.NewDecoder(reader).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("reported state = %+v, want %+v", got, want)
	}
}

func TestReporterFromEnvironmentRejectsInvalidFD(t *testing.T) {
	t.Setenv(StatusFDEnvironment, "2")
	if _, err := ReporterFromEnvironment(); err == nil {
		t.Fatal("ReporterFromEnvironment() accepted a reserved fd")
	}
}
