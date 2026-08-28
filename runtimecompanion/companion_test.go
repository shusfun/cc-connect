package runtimecompanion

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/shusfun/cc-connect/releasecontract"
	"github.com/shusfun/cc-connect/releaseinstall"
)

func TestDefaultStateDirectoryAllowsExplicitDevelopmentOverride(t *testing.T) {
	t.Setenv("CC_CONNECT_RUNTIME_STATE_DIR", filepath.Join("tmp", "runtime-dev"))
	if got, want := DefaultStateDirectory(), filepath.Clean(filepath.Join("tmp", "runtime-dev")); got != want {
		t.Fatalf("DefaultStateDirectory() = %q, want %q", got, want)
	}
}

func TestQueryStatusUsesBoundedSupervisorSocket(t *testing.T) {
	stateDirectory := shortTempDir(t)
	listener, err := net.Listen("unix", StatusSocketPath(stateDirectory))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	if err := os.Chmod(StatusSocketPath(stateDirectory), 0o600); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			done <- acceptErr
			return
		}
		defer func() { _ = connection.Close() }()
		var request socketRequest
		if decodeErr := json.NewDecoder(bufio.NewReader(connection)).Decode(&request); decodeErr != nil {
			done <- decodeErr
			return
		}
		if request.Protocol != statusProtocol || request.Method != "status" {
			done <- &unexpectedRequestError{request: request}
			return
		}
		done <- json.NewEncoder(connection).Encode(socketResponse{OK: true, Status: &SupervisorStatus{
			Protocol: statusProtocol, SupervisorPID: 101, WorkerPID: 202, WorkerGeneration: 3,
			ConnectionGeneration: 4, WorkerRunning: true, RuntimeConnected: true,
		}})
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := QueryStatus(ctx, stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if status.SupervisorPID != 101 || status.WorkerPID != 202 || status.WorkerGeneration != 3 || status.ConnectionGeneration != 4 || !status.RuntimeConnected {
		t.Fatalf("QueryStatus() = %+v", status)
	}
	info, err := os.Stat(StatusSocketPath(stateDirectory))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("status socket mode = %o, want 600", info.Mode().Perm())
	}
}

func TestReconnectDoesNotExposeStartOperation(t *testing.T) {
	stateDirectory := shortTempDir(t)
	listener, err := net.Listen("unix", StatusSocketPath(stateDirectory))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	method := make(chan string, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			method <- "accept-error"
			return
		}
		defer func() { _ = connection.Close() }()
		var request socketRequest
		_ = json.NewDecoder(connection).Decode(&request)
		method <- request.Method
		_ = json.NewEncoder(connection).Encode(socketResponse{OK: true})
	}()

	if err := Reconnect(context.Background(), stateDirectory); err != nil {
		t.Fatal(err)
	}
	if got := <-method; got != "reconnect" {
		t.Fatalf("socket method = %q, want reconnect", got)
	}
}

func TestQueryStatusOfflineErrorDirectsUserToCodexTerminal(t *testing.T) {
	_, err := QueryStatus(context.Background(), filepath.Join(t.TempDir(), "missing"))
	if err == nil || !containsAll(err.Error(), "Runtime supervisor 未在线", "Codex App 终端") {
		t.Fatalf("QueryStatus() error = %v", err)
	}
}

func TestCheckDesktopUpdateRequiresSignedManifestV2DMG(t *testing.T) {
	cosign := filepath.Join(t.TempDir(), "cosign")
	if err := os.WriteFile(cosign, []byte("test"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("COSIGN_BIN", cosign)
	original := openReleaseClient
	t.Cleanup(func() { openReleaseClient = original })
	client := &fakeReleaseClient{
		latestTag: "v0.4.0",
		release: releaseinstall.Release{Manifest: releasecontract.Manifest{
			Version: releasecontract.CurrentVersion,
			Tag:     "v0.4.0",
			Artifacts: []releasecontract.Artifact{{
				Name: "cc-connect-desktop-darwin-universal.dmg", Component: "desktop", OS: "darwin", Arch: "universal", Format: releasecontract.DesktopDMG,
			}},
		}},
	}
	openReleaseClient = func(gotCosign string) (releaseClient, error) {
		if gotCosign != cosign {
			t.Fatalf("cosign = %q, want %q", gotCosign, cosign)
		}
		return client, nil
	}

	status, err := CheckDesktopUpdate(context.Background(), "v0.3.9")
	if err != nil {
		t.Fatal(err)
	}
	if !status.Available || status.CurrentTag != "v0.3.9" || status.LatestTag != "v0.4.0" {
		t.Fatalf("CheckDesktopUpdate() = %+v", status)
	}
	client.release.Manifest.Artifacts = nil
	if _, err := CheckDesktopUpdate(context.Background(), "v0.3.9"); err == nil || !strings.Contains(err.Error(), "DMG") {
		t.Fatalf("CheckDesktopUpdate() without DMG error = %v", err)
	}
}

func TestDownloadDesktopUpdateSelectsDMGArtifact(t *testing.T) {
	cosign := filepath.Join(t.TempDir(), "cosign")
	if err := os.WriteFile(cosign, []byte("test"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("COSIGN_BIN", cosign)
	original := openReleaseClient
	t.Cleanup(func() { openReleaseClient = original })
	dmg := releasecontract.Artifact{
		Name: "cc-connect-desktop-darwin-universal.dmg", Component: "desktop", OS: "darwin", Arch: "universal", Format: releasecontract.DesktopDMG,
	}
	client := &fakeReleaseClient{release: releaseinstall.Release{Manifest: releasecontract.Manifest{
		Version: releasecontract.CurrentVersion, Tag: "v0.4.0", Artifacts: []releasecontract.Artifact{dmg},
	}}}
	openReleaseClient = func(string) (releaseClient, error) { return client, nil }
	destination := filepath.Join(t.TempDir(), "update.dmg")
	if err := DownloadDesktopUpdate(context.Background(), "v0.4.0", destination); err != nil {
		t.Fatal(err)
	}
	if client.downloaded.Name != dmg.Name || client.destination != destination {
		t.Fatalf("downloaded = %+v to %q", client.downloaded, client.destination)
	}
}

type fakeReleaseClient struct {
	latestTag   string
	release     releaseinstall.Release
	downloaded  releasecontract.Artifact
	destination string
}

func (f *fakeReleaseClient) LatestTag(context.Context) (string, error) {
	return f.latestTag, nil
}

func (f *fakeReleaseClient) Fetch(context.Context, string) (releaseinstall.Release, error) {
	return f.release, nil
}

func (f *fakeReleaseClient) DownloadArtifact(_ context.Context, _ releaseinstall.Release, artifact releasecontract.Artifact, destination string) error {
	f.downloaded = artifact
	f.destination = destination
	return nil
}

type unexpectedRequestError struct {
	request socketRequest
}

func (e *unexpectedRequestError) Error() string {
	raw, _ := json.Marshal(e.request)
	return "unexpected request: " + string(raw)
}

func containsAll(value string, fragments ...string) bool {
	for _, fragment := range fragments {
		if !strings.Contains(value, fragment) {
			return false
		}
	}
	return true
}

func shortTempDir(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "ccrt-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	return directory
}
