package releasecontract

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
)

const (
	Repository     = "shusfun/cc-connect"
	Workflow       = ".github/workflows/release.yml"
	CurrentVersion = 2
	TransitionV1   = 1
	ArchiveTarGzip = "tar.gz"
	DesktopAppZIP  = "app-zip"
	DesktopDMG     = "dmg"
)

type Artifact struct {
	Name      string `json:"name"`
	Component string `json:"component"`
	OS        string `json:"os"`
	Arch      string `json:"arch"`
	Format    string `json:"format,omitempty"`
	SHA256    string `json:"sha256"`
	Size      int64  `json:"size"`
}

type Manifest struct {
	Version             int        `json:"version"`
	Repository          string     `json:"repository"`
	Workflow            string     `json:"workflow"`
	Tag                 string     `json:"tag"`
	CommitSHA           string     `json:"commit_sha"`
	RuntimeContractHash string     `json:"runtime_contract_hash"`
	ControlSchema       int        `json:"control_schema"`
	GeneratedAt         time.Time  `json:"generated_at"`
	Artifacts           []Artifact `json:"artifacts"`
}

func Decode(raw []byte) (Manifest, error) {
	var manifest Manifest
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return Manifest{}, fmt.Errorf("release manifest: decode: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return Manifest{}, errors.New("release manifest: trailing JSON is not allowed")
	}
	if err := manifest.Validate(); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

func (m Manifest) Validate() error {
	if (m.Version != TransitionV1 && m.Version != CurrentVersion) || m.Repository != Repository || m.Workflow != Workflow {
		return errors.New("release manifest: unsupported version, repository, or workflow")
	}
	if !strings.HasPrefix(m.Tag, "v") || strings.TrimSpace(m.Tag) != m.Tag || len(m.Tag) < 2 {
		return errors.New("release manifest: valid v-prefixed tag is required")
	}
	if len(m.CommitSHA) != 40 {
		return errors.New("release manifest: full commit SHA is required")
	}
	if _, err := hex.DecodeString(m.CommitSHA); err != nil {
		return errors.New("release manifest: commit SHA is invalid")
	}
	if strings.TrimSpace(m.RuntimeContractHash) == "" || m.ControlSchema < 1 || m.GeneratedAt.IsZero() {
		return errors.New("release manifest: compatibility metadata is incomplete")
	}
	required := requiredArtifacts(m.Version)
	seen := make(map[string]struct{}, len(m.Artifacts))
	for _, artifact := range m.Artifacts {
		format := artifact.Format
		if m.Version == TransitionV1 {
			if format != "" {
				return errors.New("release manifest: v1 artifact format must be omitted")
			}
			format = ArchiveTarGzip
		} else if format == "" {
			return errors.New("release manifest: v2 artifact format is required")
		}
		key := artifact.Component + "/" + artifact.OS + "/" + artifact.Arch + "/" + format
		if _, expected := required[key]; !expected {
			return fmt.Errorf("release manifest: unexpected artifact target %q", key)
		}
		if _, duplicate := seen[key]; duplicate {
			return fmt.Errorf("release manifest: duplicate artifact target %q", key)
		}
		seen[key] = struct{}{}
		if strings.TrimSpace(artifact.Name) == "" || strings.ContainsAny(artifact.Name, `/\\`) || artifact.Size < 1 || len(artifact.SHA256) != 64 {
			return fmt.Errorf("release manifest: invalid artifact metadata for %q", key)
		}
		if _, err := hex.DecodeString(artifact.SHA256); err != nil || strings.ToLower(artifact.SHA256) != artifact.SHA256 {
			return fmt.Errorf("release manifest: invalid SHA-256 for %q", key)
		}
	}
	if len(seen) != len(required) {
		return errors.New("release manifest: required platform artifacts are incomplete")
	}
	return nil
}

func requiredArtifacts(version int) map[string]struct{} {
	required := map[string]struct{}{
		"control/linux/amd64/tar.gz": {}, "control/linux/arm64/tar.gz": {},
		"server/linux/amd64/tar.gz": {}, "server/linux/arm64/tar.gz": {},
		"deployhost/linux/amd64/tar.gz": {}, "deployhost/linux/arm64/tar.gz": {},
		"runtime/darwin/amd64/tar.gz": {}, "runtime/darwin/arm64/tar.gz": {},
	}
	if version == CurrentVersion {
		required["desktop/darwin/universal/app-zip"] = struct{}{}
		required["desktop/darwin/universal/dmg"] = struct{}{}
	}
	return required
}

func (m Manifest) Artifact(component, osName, arch string) (Artifact, bool) {
	for _, artifact := range m.Artifacts {
		if artifact.Component == component && artifact.OS == osName && artifact.Arch == arch {
			return artifact, true
		}
	}
	return Artifact{}, false
}

func (m Manifest) ArtifactWithFormat(component, osName, arch, format string) (Artifact, bool) {
	for _, artifact := range m.Artifacts {
		if artifact.Component == component && artifact.OS == osName && artifact.Arch == arch && artifact.Format == format {
			return artifact, true
		}
	}
	return Artifact{}, false
}
