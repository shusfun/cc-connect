package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeCodexSettingsFixture(t *testing.T) string {
	t.Helper()
	directory := t.TempDir()
	path := filepath.Join(directory, "config.toml")
	raw := `data_dir = "` + directory + `"
language = "zh"
attachment_send = "on"

[[projects]]
name = "codex-runtime"

[projects.agent]
type = "codexapp"

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "cli_test"
app_secret = "secret-value"
allow_from = "ou_1"
`
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestControlOwnedGlobalSettingsReadAndWrite(t *testing.T) {
	path := writeCodexSettingsFixture(t)
	language, idle := "en", 45
	if err := SaveGlobalSettingsAt(path, GlobalSettingsUpdate{Language: &language, IdleTimeoutMins: &idle}); err != nil {
		t.Fatal(err)
	}
	settings, err := ReadGlobalSettingsAt(path)
	if err != nil {
		t.Fatal(err)
	}
	if settings["language"] != "en" || settings["idle_timeout_mins"] != 45 {
		t.Fatalf("settings = %#v", settings)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `app_secret = "secret-value"`) {
		t.Fatal("unrelated Feishu secret was not preserved")
	}
}

func TestFeishuSettingsNeverReturnSecretAndPreserveOmittedSecret(t *testing.T) {
	path := writeCodexSettingsFixture(t)
	settings, err := ReadFeishuSettingsAt(path)
	if err != nil {
		t.Fatal(err)
	}
	if !settings.Enabled || settings.AppID != "cli_test" || !settings.HasAppSecret || settings.AllowFrom != "ou_1" {
		t.Fatalf("settings = %#v", settings)
	}
	appID, allow := "cli_updated", "ou_2"
	updated, err := SaveFeishuSettingsAt(path, FeishuSettingsUpdate{AppID: &appID, AllowFrom: &allow})
	if err != nil {
		t.Fatal(err)
	}
	if updated.AppID != appID || !updated.HasAppSecret || updated.AllowFrom != allow {
		t.Fatalf("updated = %#v", updated)
	}
	raw, _ := os.ReadFile(path)
	if !strings.Contains(string(raw), `app_secret = "secret-value"`) {
		t.Fatal("omitted secret was cleared")
	}
	disabled := false
	if _, err := SaveFeishuSettingsAt(path, FeishuSettingsUpdate{Enabled: &disabled}); err != nil {
		t.Fatal(err)
	}
	settings, err = ReadFeishuSettingsAt(path)
	if err != nil || settings.Enabled {
		t.Fatalf("disabled settings = %#v, %v", settings, err)
	}
}
