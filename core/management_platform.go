package core

import (
	"context"
	"errors"
	"sync"
)

// ManagementMessageDispatcher is implemented by a platform that accepts
// browser/API-originated messages and feeds them through Engine.ReceiveMessage.
type ManagementMessageDispatcher interface {
	DispatchManagementMessage(message *Message) error
}

// ManagementPlatform is an in-process platform boundary for the Web console.
// Replies are observed by polling the authoritative agent snapshot.
type ManagementPlatform struct {
	mu      sync.RWMutex
	handler MessageHandler
	stopped bool
}

func NewManagementPlatform() *ManagementPlatform { return &ManagementPlatform{} }
func (p *ManagementPlatform) Name() string       { return "web" }
func (p *ManagementPlatform) Start(handler MessageHandler) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.handler = handler
	p.stopped = false
	return nil
}
func (p *ManagementPlatform) Stop() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.stopped = true
	p.handler = nil
	return nil
}
func (p *ManagementPlatform) Reply(context.Context, any, string) error { return nil }
func (p *ManagementPlatform) Send(context.Context, any, string) error  { return nil }
func (p *ManagementPlatform) DispatchManagementMessage(message *Message) error {
	p.mu.RLock()
	handler, stopped := p.handler, p.stopped
	p.mu.RUnlock()
	if stopped || handler == nil {
		return errors.New("management platform is unavailable")
	}
	if message == nil {
		return errors.New("management message is required")
	}
	handler(p, message)
	return nil
}

var _ Platform = (*ManagementPlatform)(nil)
var _ ManagementMessageDispatcher = (*ManagementPlatform)(nil)
