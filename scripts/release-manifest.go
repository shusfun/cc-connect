package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/shusfun/cc-connect/controlstore"
	"github.com/shusfun/cc-connect/releasecontract"
	"github.com/shusfun/cc-connect/runtimeprotocol"
	"golang.org/x/mod/semver"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	directory := requiredEnvironment("RELEASE_DIST")
	tag := requiredEnvironment("RELEASE_TAG")
	commit := requiredEnvironment("RELEASE_COMMIT")
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	var artifacts []releasecontract.Artifact
	version := manifestVersion(tag)
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		artifact, ok := artifactFromName(entry.Name())
		if !ok {
			continue
		}
		if version == releasecontract.TransitionV1 && artifact.Component == "desktop" {
			continue
		}
		if version == releasecontract.TransitionV1 {
			artifact.Format = ""
		}
		path := filepath.Join(directory, entry.Name())
		raw, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		digest := sha256.Sum256(raw)
		artifact.SHA256 = hex.EncodeToString(digest[:])
		artifact.Size = info.Size()
		artifacts = append(artifacts, artifact)
	}
	sort.Slice(artifacts, func(i, j int) bool { return artifacts[i].Name < artifacts[j].Name })
	manifest := releasecontract.Manifest{
		Version: version, Repository: releasecontract.Repository, Workflow: releasecontract.Workflow,
		Tag: tag, CommitSHA: commit, RuntimeContractHash: runtimeprotocol.ContractHash,
		ControlSchema: controlstore.SchemaVersion,
		GeneratedAt:   time.Now().UTC(), Artifacts: artifacts,
	}
	if err := manifest.Validate(); err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Join(directory, "manifest.json"), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(manifest); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}

func manifestVersion(tag string) int {
	// v0.3.x 是唯一的 Control 迁移窗口；v0.4.0 起 writer 永久切到 v2。
	if semver.IsValid(tag) && semver.Compare(semver.MajorMinor(tag), "v0.4") < 0 {
		return releasecontract.TransitionV1
	}
	return releasecontract.CurrentVersion
}

func artifactFromName(name string) (releasecontract.Artifact, bool) {
	if name == "cc-connect-desktop-darwin-universal-app.zip" {
		return releasecontract.Artifact{Name: name, Component: "desktop", OS: "darwin", Arch: "universal", Format: releasecontract.DesktopAppZIP}, true
	}
	if name == "cc-connect-desktop-darwin-universal.dmg" {
		return releasecontract.Artifact{Name: name, Component: "desktop", OS: "darwin", Arch: "universal", Format: releasecontract.DesktopDMG}, true
	}
	base := strings.TrimSuffix(name, ".tar.gz")
	parts := strings.Split(base, "-")
	if len(parts) != 5 || parts[0] != "cc" || parts[1] != "connect" {
		return releasecontract.Artifact{}, false
	}
	component, osName, arch := parts[2], parts[3], parts[4]
	return releasecontract.Artifact{Name: name, Component: component, OS: osName, Arch: arch, Format: releasecontract.ArchiveTarGzip}, true
}

func requiredEnvironment(name string) string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		fmt.Fprintf(os.Stderr, "%s is required\n", name)
		os.Exit(2)
	}
	return value
}
