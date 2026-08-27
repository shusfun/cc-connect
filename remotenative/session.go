package remotenative

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/chenhg5/cc-connect/core"
	"github.com/chenhg5/cc-connect/runtimeprotocol"
)

type remoteSession struct {
	backend   *Backend
	ctx       context.Context
	cancel    context.CancelFunc
	events    chan core.Event
	id        string
	projectID string
	title     string
	hostID    string
	mu        sync.RWMutex
	alive     atomic.Bool
	closeOnce sync.Once
	wg        sync.WaitGroup
}

func (s *remoteSession) Send(prompt, messageID string, images []core.ImageAttachment, files []core.FileAttachment) error {
	if !s.alive.Load() {
		return errors.New("remote codex app session: closed")
	}
	if len(images) > 0 || len(files) > 0 {
		return errors.New("remote codex app session: attachments are unavailable")
	}
	if strings.TrimSpace(prompt) == "" {
		return errors.New("remote codex app session: prompt is required")
	}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		taskID := s.CurrentSessionID()
		if taskID == "" {
			s.mu.RLock()
			projectID, title := s.projectID, s.title
			s.mu.RUnlock()
			created, err := s.backend.CreateSession(s.ctx, core.AgentSessionCreateRequest{ProjectID: projectID, Prompt: prompt, Title: title, UseLocal: true})
			if err != nil {
				s.emit(core.Event{Type: core.EventError, Error: err, Done: true})
				return
			}
			s.mu.Lock()
			s.id = created.ID
			s.mu.Unlock()
			s.observeCreated(created)
			return
		}
		s.mu.RLock()
		hostID := s.hostID
		s.mu.RUnlock()
		location, err := s.backend.locationForTask(s.ctx, taskID, hostID)
		if err != nil {
			s.emit(core.Event{Type: core.EventError, Error: err, Done: true})
			return
		}
		var result runtimeprotocol.TaskSendResult
		err = s.backend.rpc(s.ctx, location.deviceID, runtimeprotocol.MethodTaskSend, runtimeprotocol.TaskSendRequest{TaskRef: runtimeprotocol.TaskRef{TaskID: taskID, HostID: location.nativeHostID}, Prompt: prompt, MessageID: messageID}, &result)
		if err != nil {
			s.emit(core.Event{Type: core.EventError, Error: err, Done: true})
			return
		}
		if result.TaskID != "" {
			s.mu.Lock()
			s.id = result.TaskID
			s.mu.Unlock()
		}
		if result.Content != "" {
			s.emit(core.Event{Type: core.EventText, Content: result.Content, SessionID: s.CurrentSessionID()})
		}
		s.emit(core.Event{Type: core.EventResult, SessionID: s.CurrentSessionID(), Done: true})
	}()
	return nil
}

func (s *remoteSession) observeCreated(created core.AgentSessionInfo) {
	cursor := ""
	for {
		snapshot, err := s.backend.WaitSession(s.ctx, created.ID, created.HostID, cursor, 30*time.Second)
		if err != nil {
			s.emit(core.Event{Type: core.EventError, Error: err, SessionID: created.ID, Done: true})
			return
		}
		if snapshot.WaitCursor != "" {
			cursor = snapshot.WaitCursor
		}
		if strings.EqualFold(snapshot.Session.Status, "active") {
			continue
		}
		for index := len(snapshot.History) - 1; index >= 0; index-- {
			if snapshot.History[index].Role == "assistant" && strings.TrimSpace(snapshot.History[index].Content) != "" {
				s.emit(core.Event{Type: core.EventText, Content: snapshot.History[index].Content, SessionID: created.ID})
				break
			}
		}
		s.emit(core.Event{Type: core.EventResult, SessionID: created.ID, Done: true})
		return
	}
}

func (s *remoteSession) RespondPermission(string, core.PermissionResult) error {
	return errors.New("remote codex app session: interactive response capability is unavailable")
}
func (s *remoteSession) Events() <-chan core.Event { return s.events }
func (s *remoteSession) CurrentSessionID() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.id
}
func (s *remoteSession) SetCreationTarget(projectID, title string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.projectID = projectID
	s.title = title
}
func (s *remoteSession) SetHostID(hostID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hostID = hostID
}
func (s *remoteSession) Alive() bool { return s.alive.Load() }
func (s *remoteSession) Close() error {
	s.closeOnce.Do(func() { s.alive.Store(false); s.cancel(); s.wg.Wait(); close(s.events) })
	return nil
}
func (s *remoteSession) emit(event core.Event) {
	select {
	case s.events <- event:
	case <-s.ctx.Done():
	}
}

var _ core.AgentSession = (*remoteSession)(nil)
var _ core.AgentSessionCreationTarget = (*remoteSession)(nil)
var _ core.AgentSessionHostTarget = (*remoteSession)(nil)
