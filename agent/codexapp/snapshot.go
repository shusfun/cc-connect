package codexapp

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/shusfun/cc-connect/core"
)

type taskSnapshotResponse struct {
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
	Turns []taskTurnResponse `json:"turns"`
}

type taskTurnResponse struct {
	ID          string            `json:"id"`
	Status      string            `json:"status"`
	StartedAt   int64             `json:"startedAt"`
	CompletedAt int64             `json:"completedAt"`
	Items       []json.RawMessage `json:"items"`
}

func decodeTaskSnapshot(raw json.RawMessage) (core.AgentTaskSnapshot, error) {
	var response taskSnapshotResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return core.AgentTaskSnapshot{}, fmt.Errorf("codex app: decode typed task snapshot: %w", err)
	}
	if strings.TrimSpace(response.Thread.ID) == "" {
		return core.AgentTaskSnapshot{}, fmt.Errorf("codex app: task snapshot has no task id")
	}
	turns := make([]core.AgentTaskTurn, 0, len(response.Turns))
	for turnIndex, source := range response.Turns {
		turn, err := decodeTurn(source, turnIndex)
		if err != nil {
			return core.AgentTaskSnapshot{}, err
		}
		turns = append(turns, turn)
	}
	if response.Page.Order == "newest_first" {
		for left, right := 0, len(turns)-1; left < right; left, right = left+1, right-1 {
			turns[left], turns[right] = turns[right], turns[left]
		}
	}
	return core.AgentTaskSnapshot{
		Task: core.AgentSessionInfo{
			ID: response.Thread.ID, Summary: response.Thread.Title,
			ModifiedAt: unixTime(response.Thread.UpdatedAt), CWD: response.Thread.CWD,
			HostID: response.Thread.HostID, Status: response.Thread.Status.Type,
		},
		Turns: turns,
		Page: core.AgentTaskPage{
			Cursor: response.Page.NextCursor, HasMore: response.Page.HasMore, Order: "oldest_first",
		},
	}, nil
}

func decodeTurn(source taskTurnResponse, turnIndex int) (core.AgentTaskTurn, error) {
	items := make([]core.AgentTaskItem, 0, len(source.Items))
	for itemIndex, rawItem := range source.Items {
		item, err := decodeItem(rawItem, source.StartedAt, itemIndex)
		if err != nil {
			return core.AgentTaskTurn{}, fmt.Errorf("codex app: decode task item: %w", err)
		}
		items = append(items, item)
	}
	turnID := strings.TrimSpace(source.ID)
	if turnID == "" {
		turnID = stableSnapshotID("turn", source.StartedAt, turnIndex, source.Items)
	}
	return core.AgentTaskTurn{
		ID: turnID, Status: source.Status, StartedAt: unixTime(source.StartedAt),
		CompletedAt: unixTime(source.CompletedAt), Items: items,
	}, nil
}

func decodeItem(rawItem json.RawMessage, startedAt int64, itemIndex int) (core.AgentTaskItem, error) {
	var header struct {
		Type    string          `json:"type"`
		ID      string          `json:"id"`
		Text    string          `json:"text"`
		Status  string          `json:"status"`
		Content json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal(rawItem, &header); err != nil {
		return core.AgentTaskItem{}, err
	}
	itemID := strings.TrimSpace(header.ID)
	if itemID == "" {
		itemID = stableSnapshotID("item", startedAt, itemIndex, []json.RawMessage{rawItem})
	}
	switch header.Type {
	case "userMessage":
		parts, err := decodeContentParts(header.Content)
		if err != nil {
			return core.AgentTaskItem{}, err
		}
		return core.AgentTaskItem{Type: "user_message", ID: itemID, Content: parts}, nil
	case "agentMessage":
		return core.AgentTaskItem{Type: "agent_message", ID: itemID, Text: header.Text}, nil
	case "plan":
		parts, err := decodeContentParts(header.Content)
		if err != nil {
			parts = nil
		}
		text := strings.TrimSpace(header.Text)
		if text == "" {
			values := make([]string, 0, len(parts))
			for _, part := range parts {
				if part.Type == "text" && strings.TrimSpace(part.Text) != "" {
					values = append(values, part.Text)
				}
			}
			text = strings.Join(values, "\n")
		}
		return core.AgentTaskItem{
			Type: "plan", ID: itemID, Text: text, Content: parts, Status: header.Status,
			RawContent: append(json.RawMessage(nil), header.Content...),
		}, nil
	default:
		return core.AgentTaskItem{Type: "unsupported", ID: itemID, SourceType: firstNonEmpty(header.Type, "unknown")}, nil
	}
}

func decodeContentParts(raw json.RawMessage) ([]core.AgentTaskContentPart, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		if strings.TrimSpace(text) == "" {
			return nil, nil
		}
		return []core.AgentTaskContentPart{{Type: "text", Text: text}}, nil
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &parts); err != nil {
		return nil, fmt.Errorf("invalid item content: %w", err)
	}
	result := make([]core.AgentTaskContentPart, 0, len(parts))
	for _, part := range parts {
		if part.Type == "text" {
			result = append(result, core.AgentTaskContentPart{Type: "text", Text: part.Text})
		}
	}
	return result, nil
}

func stableSnapshotID(prefix string, startedAt int64, index int, raw []json.RawMessage) string {
	hash := sha256.New()
	_, _ = fmt.Fprintf(hash, "%s\x00%d\x00%d\x00", prefix, startedAt, index)
	for _, value := range raw {
		_, _ = hash.Write(value)
	}
	return prefix + "_" + hex.EncodeToString(hash.Sum(nil)[:12])
}

func legacySnapshot(snapshot core.AgentTaskSnapshot) core.AgentSessionSnapshot {
	history := make([]core.HistoryEntry, 0)
	for _, turn := range snapshot.Turns {
		for _, item := range turn.Items {
			switch item.Type {
			case "user_message":
				parts := make([]string, 0, len(item.Content))
				for _, part := range item.Content {
					if part.Type == "text" && strings.TrimSpace(part.Text) != "" {
						parts = append(parts, part.Text)
					}
				}
				if len(parts) > 0 {
					history = append(history, core.HistoryEntry{Role: "user", Content: strings.Join(parts, "\n"), Timestamp: turn.StartedAt})
				}
			case "agent_message":
				if strings.TrimSpace(item.Text) != "" {
					history = append(history, core.HistoryEntry{Role: "assistant", Content: item.Text, Timestamp: turn.StartedAt})
				}
			}
		}
	}
	task := snapshot.Task
	task.MessageCount = len(history)
	return core.AgentSessionSnapshot{
		Session: task, History: history, Cursor: snapshot.Page.Cursor,
		WaitCursor: snapshot.WaitCursor, HasMore: snapshot.Page.HasMore,
	}
}
