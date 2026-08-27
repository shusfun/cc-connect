package codexapp

import (
	"encoding/json"
	"testing"
)

func schema(required ...string) json.RawMessage {
	properties := make(map[string]any)
	for _, field := range required {
		properties[field] = map[string]any{"type": "string"}
	}
	raw, _ := json.Marshal(map[string]any{"type": "object", "additionalProperties": false, "properties": properties, "required": required})
	return raw
}

func TestCompatibleToolSchemaRejectsMissingRequiredField(t *testing.T) {
	if compatibleToolSchema("send_message_to_thread", schema("threadId")) {
		t.Fatal("schema without prompt must be rejected")
	}
	if !compatibleToolSchema("send_message_to_thread", schema("threadId", "prompt")) {
		t.Fatal("expected compatible schema")
	}
}

func TestBridgeRejectsUnknownToolBeforeConnecting(t *testing.T) {
	b := &Bridge{}
	if _, err := b.Call(t.Context(), "dangerous_new_tool", map[string]any{}); err == nil {
		t.Fatal("expected audited allowlist error")
	}
}
