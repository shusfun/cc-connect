package core

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestControlHandlerExposesOnlyRuntimeActivity(t *testing.T) {
	management := NewManagementServer()
	handler := management.controlHandler()

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/internal/v1/control/runtime-activity", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("runtime activity status = %d, want 200", response.Code)
	}

	for _, path := range []string{
		"/api/v1/projects", "/api/v1/cron", "/api/v1/providers", "/api/v1/skills", "/api/v1/setup/weixin/begin",
	} {
		response = httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != http.StatusNotFound {
			t.Fatalf("legacy route %s status = %d, want 404", path, response.Code)
		}
	}
}
