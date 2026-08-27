package codexapp

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/chenhg5/cc-connect/core"
)

func decodeSnapshot(raw json.RawMessage) (core.AgentSessionSnapshot, error) {
	var response struct {
		Thread struct {
			ID        string `json:"id"`
			HostID    string `json:"hostId"`
			Title     string `json:"title"`
			CWD       string `json:"cwd"`
			UpdatedAt int64  `json:"updatedAt"`
			Status    struct {
				Type string `json:"type"`
			} `json:"status"`
		} `json:"thread"`
		Page struct {
			NextCursor string `json:"nextCursor"`
			HasMore    bool   `json:"hasMore"`
			Order      string `json:"order"`
		} `json:"page"`
		Turns []struct {
			StartedAt int64             `json:"startedAt"`
			Items     []json.RawMessage `json:"items"`
		} `json:"turns"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return core.AgentSessionSnapshot{}, fmt.Errorf("codex app: decode task snapshot: %w", err)
	}
	if response.Thread.ID == "" {
		return core.AgentSessionSnapshot{}, fmt.Errorf("codex app: task snapshot has no task id")
	}
	history := make([]core.HistoryEntry, 0)
	appendTurn := func(turn struct {
		StartedAt int64             `json:"startedAt"`
		Items     []json.RawMessage `json:"items"`
	}) {
		for _, rawItem := range turn.Items {
			var kind struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(rawItem, &kind) != nil {
				continue
			}
			switch kind.Type {
			case "userMessage":
				var item struct {
					Content []struct {
						Type string `json:"type"`
						Text string `json:"text"`
					} `json:"content"`
				}
				if json.Unmarshal(rawItem, &item) != nil {
					continue
				}
				var parts []string
				for _, content := range item.Content {
					if content.Type == "text" && strings.TrimSpace(content.Text) != "" {
						parts = append(parts, content.Text)
					}
				}
				if len(parts) > 0 {
					history = append(history, core.HistoryEntry{Role: "user", Content: strings.Join(parts, "\n"), Timestamp: unixTime(turn.StartedAt)})
				}
			case "agentMessage":
				var item struct {
					Text string `json:"text"`
				}
				if json.Unmarshal(rawItem, &item) == nil && strings.TrimSpace(item.Text) != "" {
					history = append(history, core.HistoryEntry{Role: "assistant", Content: item.Text, Timestamp: unixTime(turn.StartedAt)})
				}
			}
		}
	}
	if response.Page.Order == "newest_first" {
		for i := len(response.Turns) - 1; i >= 0; i-- {
			appendTurn(response.Turns[i])
		}
	} else {
		for _, turn := range response.Turns {
			appendTurn(turn)
		}
	}
	return core.AgentSessionSnapshot{Session: core.AgentSessionInfo{ID: response.Thread.ID, Summary: response.Thread.Title, ModifiedAt: unixTime(response.Thread.UpdatedAt), CWD: response.Thread.CWD, HostID: response.Thread.HostID, Status: response.Thread.Status.Type, MessageCount: len(history)}, History: history, Cursor: response.Page.NextCursor, HasMore: response.Page.HasMore}, nil
}
