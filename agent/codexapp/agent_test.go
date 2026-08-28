package codexapp

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/shusfun/cc-connect/core"
)

type recordedCall struct {
	tool      string
	arguments any
}
type fakeCaller struct {
	mu        sync.Mutex
	calls     []recordedCall
	responses map[string][]json.RawMessage
	tools     map[string]bool
}

func (f *fakeCaller) Call(_ context.Context, tool string, arguments any) (json.RawMessage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, recordedCall{tool, arguments})
	queue := f.responses[tool]
	if len(queue) == 0 {
		return nil, errors.New("unexpected tool call: " + tool)
	}
	result := queue[0]
	f.responses[tool] = queue[1:]
	return result, nil
}
func (f *fakeCaller) HasTool(name string) bool { return f.tools[name] }
func (f *fakeCaller) Close() error             { return nil }
func toolResult(value string) json.RawMessage {
	payload, _ := json.Marshal(map[string]any{"success": true, "contentItems": []map[string]any{{"type": "inputText", "text": value}}})
	return payload
}

func TestActiveWriterTaskUsesDesktopToolsWithoutThreadResume(t *testing.T) {
	caller := &fakeCaller{tools: map[string]bool{}, responses: map[string][]json.RawMessage{
		"send_message_to_thread": {toolResult(`{"ok":true}`)},
		"wait_threads":           {toolResult(`{"status":"completed","cursor":"next"}`)},
		"read_thread": {
			toolResult(`{"thread":{"id":"task-active","hostId":"local","title":"活动任务","cwd":"/repo","updatedAt":99,"status":{"type":"idle"}},"page":{"order":"newest_first","hasMore":false},"turns":[{"startedAt":90,"items":[{"type":"agentMessage","text":"旧答复","phase":"final"}]}]}`),
			toolResult(`{"thread":{"id":"task-active","hostId":"local","title":"活动任务","cwd":"/repo","updatedAt":100,"status":{"type":"idle"}},"page":{"order":"newest_first","hasMore":false},"turns":[{"startedAt":100,"items":[{"type":"userMessage","content":[{"type":"text","text":"继续"}]},{"type":"agentMessage","text":"已完成","phase":"final"}]}]}`),
		},
	}}
	agent := newAgentWithCaller(caller)
	sessionValue, err := agent.StartSession(context.Background(), "task-active")
	if err != nil {
		t.Fatal(err)
	}
	session := sessionValue.(*Session)
	if err := session.Send("继续", "msg-1", nil, nil); err != nil {
		t.Fatal(err)
	}
	deadline := time.After(time.Second)
	for {
		select {
		case event := <-session.Events():
			if event.Done {
				goto done
			}
		case <-deadline:
			t.Fatal("timed out waiting for Desktop App task")
		}
	}
done:
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	caller.mu.Lock()
	defer caller.mu.Unlock()
	want := []string{"read_thread", "send_message_to_thread", "wait_threads", "read_thread"}
	if len(caller.calls) != len(want) {
		t.Fatalf("calls = %#v, want %v", caller.calls, want)
	}
	for i, call := range caller.calls {
		if call.tool != want[i] {
			t.Fatalf("call %d = %q, want %q", i, call.tool, want[i])
		}
		if call.tool == "thread/resume" {
			t.Fatal("must not resume a Desktop App task writer")
		}
	}
}

func TestSessionCloseOnlyStopsObservation(t *testing.T) {
	caller := &fakeCaller{responses: map[string][]json.RawMessage{}}
	agent := newAgentWithCaller(caller)
	sessionValue, err := agent.StartSession(context.Background(), "task-owned-by-app")
	if err != nil {
		t.Fatal(err)
	}
	if err := sessionValue.Close(); err != nil {
		t.Fatal(err)
	}
	caller.mu.Lock()
	defer caller.mu.Unlock()
	if len(caller.calls) != 0 {
		t.Fatalf("Close sent Desktop App mutations: %#v", caller.calls)
	}
}

func TestReadSessionParsesAuthoritativeHistory(t *testing.T) {
	caller := &fakeCaller{responses: map[string][]json.RawMessage{"read_thread": {toolResult(`{"thread":{"id":"t1","hostId":"local","title":"标题","cwd":"/repo","updatedAt":20,"status":{"type":"completed"}},"page":{"order":"newest_first","nextCursor":"older","hasMore":true},"turns":[{"startedAt":20,"items":[{"type":"userMessage","content":[{"type":"text","text":"后"}]},{"type":"agentMessage","text":"答复二"}]},{"startedAt":10,"items":[{"type":"userMessage","content":[{"type":"text","text":"前"}]},{"type":"agentMessage","text":"答复一"}]}]}`)}}}
	agent := newAgentWithCaller(caller)
	snapshot, err := agent.ReadSession(context.Background(), "t1", "local", "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.History) != 4 || snapshot.History[0].Content != "前" || snapshot.History[3].Content != "答复二" {
		t.Fatalf("unexpected history: %#v", snapshot.History)
	}
	if snapshot.Cursor != "older" || !snapshot.HasMore {
		t.Fatalf("unexpected page: %#v", snapshot)
	}
}

func TestTaskCatalogNeverExceedsCodexListThreadsLimit(t *testing.T) {
	caller := &fakeCaller{responses: map[string][]json.RawMessage{
		"list_projects": {
			toolResult(`{"projects":[{"projectId":"project-1","label":"项目","hostId":"local"}]}`),
			toolResult(`{"projects":[{"projectId":"project-1","label":"项目","hostId":"local"}]}`),
		},
		"list_threads": {toolResult(`{"pinnedThreads":[],"threads":[]}`), toolResult(`{"pinnedThreads":[],"threads":[]}`)},
	}}
	agent := newAgentWithCaller(caller)
	if _, err := agent.ListSessionPage(context.Background(), core.AgentSessionListRequest{ProjectID: "project-1", Limit: 50}); err != nil {
		t.Fatal(err)
	}
	if _, err := agent.SearchTasks(context.Background(), core.AgentTaskSearchRequest{Query: "needle", Limit: 100}); err != nil {
		t.Fatal(err)
	}
	caller.mu.Lock()
	defer caller.mu.Unlock()
	for _, call := range caller.calls {
		if call.tool != "list_threads" {
			continue
		}
		arguments, ok := call.arguments.(map[string]any)
		if !ok || arguments["limit"] != 50 {
			t.Fatalf("list_threads arguments = %#v, want limit 50", call.arguments)
		}
	}
}

func TestReadTaskPreservesTypedItemsAndStableIDs(t *testing.T) {
	caller := &fakeCaller{responses: map[string][]json.RawMessage{"read_thread": {toolResult(`{
		"thread":{"id":"t1","hostId":"local","title":"标题","updatedAt":20,"status":{"type":"completed"}},
		"page":{"order":"newest_first","nextCursor":"older","hasMore":true},
		"turns":[{
			"id":"turn-2","status":"completed","startedAt":20,"completedAt":21,
			"items":[
				{"id":"user-2","type":"userMessage","content":[{"type":"text","text":"继续"}]},
				{"id":"plan-2","type":"plan","status":"in_progress","text":"检查契约","content":{"steps":[{"title":"读取 schema","status":"completed"}]}},
				{"id":"tool-2","type":"toolCall","name":"rg"}
			]
		},{
			"id":"turn-1","status":"completed","startedAt":10,
			"items":[{"id":"agent-1","type":"agentMessage","text":"开始"}]
		}]
	}`)}}}
	agent := newAgentWithCaller(caller)
	snapshot, err := agent.ReadTask(context.Background(), "t1", "local", "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Page.Order != "oldest_first" || snapshot.Page.Cursor != "older" || !snapshot.Page.HasMore {
		t.Fatalf("unexpected page: %#v", snapshot.Page)
	}
	if len(snapshot.Turns) != 2 || snapshot.Turns[0].ID != "turn-1" || snapshot.Turns[1].ID != "turn-2" {
		t.Fatalf("unexpected turn order or IDs: %#v", snapshot.Turns)
	}
	items := snapshot.Turns[1].Items
	if len(items) != 3 || items[0].ID != "user-2" || items[0].Type != "user_message" {
		t.Fatalf("unexpected user item: %#v", items)
	}
	if items[1].ID != "plan-2" || items[1].Type != "plan" || items[1].Status != "in_progress" || items[1].Text != "检查契约" {
		t.Fatalf("unexpected plan item: %#v", items[1])
	}
	if string(items[1].RawContent) != `{"steps":[{"title":"读取 schema","status":"completed"}]}` {
		t.Fatalf("plan raw content was not preserved: %s", items[1].RawContent)
	}
	if items[2].ID != "tool-2" || items[2].Type != "unsupported" || items[2].SourceType != "toolCall" {
		t.Fatalf("unexpected unsupported item: %#v", items[2])
	}
}

func TestCreateSessionUsesDesktopAppAndNeverExecutesCodex(t *testing.T) {
	caller := &fakeCaller{responses: map[string][]json.RawMessage{"create_thread": {toolResult(`{"threadId":"new-task","hostId":"local"}`)}}}
	agent := newAgentWithCaller(caller)
	agent.projectID = "project-1"
	info, err := agent.CreateSession(context.Background(), core.AgentSessionCreateRequest{Prompt: "第一条消息"})
	if err != nil {
		t.Fatal(err)
	}
	if info.ID != "new-task" {
		t.Fatalf("task id = %q", info.ID)
	}
	caller.mu.Lock()
	defer caller.mu.Unlock()
	if len(caller.calls) != 1 || caller.calls[0].tool != "create_thread" {
		t.Fatalf("unexpected calls: %#v", caller.calls)
	}
}

func TestUpdateMetadataRequiresDynamicCapability(t *testing.T) {
	caller := &fakeCaller{tools: map[string]bool{}, responses: map[string][]json.RawMessage{}}
	agent := newAgentWithCaller(caller)
	title := "新标题"
	if err := agent.UpdateSessionMetadata(context.Background(), "t1", "", core.AgentSessionMetadataPatch{Title: &title}); err == nil {
		t.Fatal("expected unavailable capability error")
	}
}

func TestSessionCapabilitiesExposeOnlyAuditedCompatibleTools(t *testing.T) {
	caller := &fakeCaller{tools: map[string]bool{
		"create_thread": true, "set_thread_title": true, "set_thread_archived": true,
		"dangerous_new_tool": true,
	}}
	agent := newAgentWithCaller(caller)
	capabilities, err := agent.SessionCapabilities(context.Background(), "local")
	if err != nil {
		t.Fatal(err)
	}
	if !capabilities.Create.Supported || !capabilities.Rename.Supported || !capabilities.Archive.Supported {
		t.Fatalf("expected audited tools to be available: %#v", capabilities)
	}
	if capabilities.Pin.Supported || capabilities.Fork.Supported || capabilities.Handoff.Supported || capabilities.InteractiveResponse.Supported {
		t.Fatalf("unexpected unsupported capability exposure: %#v", capabilities)
	}
	if capabilities.Pin.Reason == "" || capabilities.InteractiveResponse.Reason == "" {
		t.Fatalf("unsupported capabilities must explain why: %#v", capabilities)
	}
}
