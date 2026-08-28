package controlplane

import (
	"net/http"
	"path/filepath"

	appconfig "github.com/shusfun/cc-connect/config"
)

func (s *Server) serverConfigPath() string {
	return filepath.Join(s.config.AppDirectory, "config.toml")
}

func (s *Server) handleSettings(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		settings, err := appconfig.ReadGlobalSettingsAt(s.serverConfigPath())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, false, nil, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, true, settings, "")
	case http.MethodPatch:
		var update appconfig.GlobalSettingsUpdate
		if err := decodeRequest(r, &update); err != nil {
			writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
			return
		}
		if err := appconfig.SaveGlobalSettingsAt(s.serverConfigPath(), update); err != nil {
			writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
			return
		}
		settings, err := appconfig.ReadGlobalSettingsAt(s.serverConfigPath())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, false, nil, err.Error())
			return
		}
		_ = s.store.RecordAudit(r.Context(), "admin", "settings_updated", "server_config", "succeeded", nil)
		writeJSON(w, http.StatusOK, true, settings, "")
	default:
		writeJSON(w, http.StatusMethodNotAllowed, false, nil, "GET or PATCH only")
	}
}

func (s *Server) handleFeishuSettings(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		settings, err := appconfig.ReadFeishuSettingsAt(s.serverConfigPath())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, false, nil, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, true, settings, "")
	case http.MethodPatch:
		var update appconfig.FeishuSettingsUpdate
		if err := decodeRequest(r, &update); err != nil {
			writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
			return
		}
		settings, err := appconfig.SaveFeishuSettingsAt(s.serverConfigPath(), update)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, false, nil, err.Error())
			return
		}
		_ = s.store.RecordAudit(r.Context(), "admin", "feishu_settings_updated", "server_config", "succeeded", nil)
		writeJSON(w, http.StatusOK, true, settings, "")
	default:
		writeJSON(w, http.StatusMethodNotAllowed, false, nil, "GET or PATCH only")
	}
}
