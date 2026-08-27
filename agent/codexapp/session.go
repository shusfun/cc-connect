package codexapp

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/chenhg5/cc-connect/core"
)

type Session struct {
	agent     *Agent
	ctx       context.Context
	cancel    context.CancelFunc
	events    chan core.Event
	id        atomic.Value
	hostID    atomic.Value
	projectID atomic.Value
	title     atomic.Value
	alive     atomic.Bool
	closeOnce sync.Once
	sendMu    sync.Mutex
	wg        sync.WaitGroup
}

func (s *Session) Send(prompt, messageID string, images []core.ImageAttachment, files []core.FileAttachment) error {
	if !s.alive.Load() {
		return errors.New("codex app session: closed")
	}
	if len(images) > 0 || len(files) > 0 {
		return errors.New("codex app session: attachments are not supported by the current Desktop App tool contract")
	}
	prompt = strings.TrimSpace(prompt)
	if prompt == "" {
		return errors.New("codex app session: prompt is required")
	}
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	threadID := s.CurrentSessionID()
	baselineAssistant := ""
	if threadID != "" {
		if snapshot, err := s.agent.ReadSession(s.ctx, threadID, s.currentHostID(), "", 2); err == nil {
			baselineAssistant = latestAssistant(snapshot.History)
		}
	}
	if threadID == "" {
		created, err := s.agent.CreateSession(s.ctx, core.AgentSessionCreateRequest{ProjectID: s.creationProjectID(), Prompt: prompt, Title: s.creationTitle()})
		if err != nil {
			return err
		}
		s.id.Store(created.ID)
		s.hostID.Store(created.HostID)
		threadID = created.ID
	} else {
		arguments := map[string]any{"threadId": threadID, "prompt": prompt}
		if hostID := s.currentHostID(); hostID != "" {
			arguments["hostId"] = hostID
		}
		if _, err := s.agent.callJSON(s.ctx, "send_message_to_thread", arguments); err != nil {
			return err
		}
	}
	s.wg.Add(1)
	go s.observe(threadID, baselineAssistant)
	return nil
}

func (s *Session) observe(threadID, baselineAssistant string) {
	defer s.wg.Done()
	cursor := ""
	reconnectDeadline := time.Time{}
	for {
		snapshot, err := s.agent.WaitSession(s.ctx, threadID, s.currentHostID(), cursor, 30*time.Second)
		if err != nil {
			if s.ctx.Err() != nil {
				return
			}
			if reconnectDeadline.IsZero() {
				reconnectDeadline = time.Now().Add(30 * time.Second)
			}
			if time.Now().After(reconnectDeadline) {
				s.emit(core.Event{Type: core.EventError, Error: fmt.Errorf("codex app session: Desktop App reconnect timed out: %w", err), Done: true})
				return
			}
			timer := time.NewTimer(time.Second)
			select {
			case <-timer.C:
			case <-s.ctx.Done():
				timer.Stop()
				return
			}
			continue
		}
		reconnectDeadline = time.Time{}
		if snapshot.WaitCursor != "" {
			cursor = snapshot.WaitCursor
		}
		if strings.EqualFold(snapshot.Session.Status, "active") {
			continue
		}
		answer := latestAssistant(snapshot.History)
		if answer != "" && answer != baselineAssistant {
			s.emit(core.Event{Type: core.EventText, Content: answer, SessionID: threadID})
		}
		s.emit(core.Event{Type: core.EventResult, SessionID: threadID, Done: true})
		return
	}
}

func latestAssistant(history []core.HistoryEntry) string {
	for i := len(history) - 1; i >= 0; i-- {
		if history[i].Role == "assistant" {
			return history[i].Content
		}
	}
	return ""
}

func (s *Session) RespondPermission(string, core.PermissionResult) error {
	return errors.New("codex app session: interactive response capability is unavailable")
}
func (s *Session) Events() <-chan core.Event { return s.events }
func (s *Session) CurrentSessionID() string {
	value := s.id.Load()
	if value == nil {
		return ""
	}
	result, _ := value.(string)
	return result
}
func (s *Session) currentHostID() string {
	value := s.hostID.Load()
	if value == nil {
		return ""
	}
	result, _ := value.(string)
	return result
}
func (s *Session) SetCreationTarget(projectID, title string) {
	s.projectID.Store(projectID)
	s.title.Store(title)
}
func (s *Session) SetHostID(hostID string) { s.hostID.Store(hostID) }
func (s *Session) creationProjectID() string {
	value := s.projectID.Load()
	if value == nil {
		return ""
	}
	result, _ := value.(string)
	return result
}
func (s *Session) creationTitle() string {
	value := s.title.Load()
	if value == nil {
		return ""
	}
	result, _ := value.(string)
	return result
}
func (s *Session) Alive() bool { return s.alive.Load() }
func (s *Session) Close() error {
	s.closeOnce.Do(func() { s.alive.Store(false); s.cancel(); s.wg.Wait(); close(s.events) })
	return nil
}
func (s *Session) emit(event core.Event) {
	select {
	case s.events <- event:
	case <-s.ctx.Done():
	}
}

var _ core.AgentSession = (*Session)(nil)
var _ core.AgentSessionCreationTarget = (*Session)(nil)
var _ core.AgentSessionHostTarget = (*Session)(nil)

func (s *Session) String() string { return fmt.Sprintf("codexapp:%s", s.CurrentSessionID()) }
