package controlplane

import (
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/shusfun/cc-connect/controlstore"
	"github.com/shusfun/cc-connect/runtimeprotocol"
)

type Broker struct {
	store *controlstore.Store
	now   func() time.Time

	mu           sync.RWMutex
	connections  map[string]*runtimeConnection
	challenges   map[string]challenge
	generations  map[string]uint64
	closed       bool
	workspaceKey []byte
	eventSubs    map[uint64]*eventSubscription
	nextEventSub uint64
}

type eventSubscription struct {
	mu     sync.Mutex
	events chan runtimeprotocol.Envelope
	closed bool
}

func (s *eventSubscription) publish(envelope runtimeprotocol.Envelope) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return false
	}
	select {
	case s.events <- envelope:
		return true
	default:
		close(s.events)
		s.closed = true
		return false
	}
}

func (s *eventSubscription) close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.closed {
		close(s.events)
		s.closed = true
	}
}

type challenge struct {
	value     string
	expiresAt time.Time
}

type runtimeConnection struct {
	deviceID   string
	generation uint64
	conn       *websocket.Conn
	sendMu     sync.Mutex
	sendSeq    uint64
	recvGuard  runtimeprotocol.SequenceGuard
	pendingMu  sync.Mutex
	pending    map[string]chan runtimeprotocol.Envelope
	closed     chan struct{}
	closeOnce  sync.Once
}

type DeviceStatus struct {
	controlstore.Device
	Online bool `json:"online"`
}

type CatalogWorkspace struct {
	Ref         string    `json:"ref"`
	DeviceID    string    `json:"device_id"`
	DeviceName  string    `json:"device_name"`
	ProjectID   string    `json:"project_id"`
	ProjectName string    `json:"project_name"`
	HostID      string    `json:"host_id,omitempty"`
	Kind        string    `json:"kind,omitempty"`
	Git         bool      `json:"is_git_repository"`
	RootIndex   int       `json:"root_index"`
	RootName    string    `json:"root_name"`
	Available   bool      `json:"available"`
	Reason      string    `json:"reason,omitempty"`
	Order       int       `json:"order"`
	Online      bool      `json:"online"`
	UpdatedAt   time.Time `json:"updated_at"`
}

func NewBroker(store *controlstore.Store) (*Broker, error) {
	if store == nil {
		return nil, errors.New("control broker: store is required")
	}
	key, err := store.WorkspaceReferenceKey(context.Background())
	if err != nil {
		return nil, err
	}
	return &Broker{
		store: store, now: time.Now, connections: make(map[string]*runtimeConnection),
		challenges: make(map[string]challenge), generations: make(map[string]uint64), workspaceKey: key,
		eventSubs: make(map[uint64]*eventSubscription),
	}, nil
}

func (b *Broker) IssueChallenge(ctx context.Context, deviceID string) (string, time.Time, error) {
	device, err := b.store.Device(ctx, deviceID)
	if err != nil || device.RevokedAt != nil {
		return "", time.Time{}, errors.New("control broker: active device not found")
	}
	value, err := secureToken(32)
	if err != nil {
		return "", time.Time{}, err
	}
	expires := b.now().Add(2 * time.Minute)
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return "", time.Time{}, errors.New("control broker: closed")
	}
	b.challenges[deviceID] = challenge{value: value, expiresAt: expires}
	return value, expires, nil
}

func (b *Broker) authenticate(ctx context.Context, deviceID, challengeValue, signatureText string) error {
	b.mu.Lock()
	issued, ok := b.challenges[deviceID]
	delete(b.challenges, deviceID)
	b.mu.Unlock()
	if !ok || !issued.expiresAt.After(b.now()) || subtle.ConstantTimeCompare([]byte(issued.value), []byte(challengeValue)) != 1 {
		return errors.New("control broker: challenge is invalid, expired, or already consumed")
	}
	device, err := b.store.Device(ctx, deviceID)
	if err != nil || device.RevokedAt != nil {
		return errors.New("control broker: active device not found")
	}
	signature, err := base64.RawURLEncoding.DecodeString(signatureText)
	if err != nil {
		return errors.New("control broker: invalid challenge signature encoding")
	}
	message := []byte(runtimeprotocol.ContractHash + "\n" + deviceID + "\n" + challengeValue)
	if !ed25519.Verify(ed25519.PublicKey(device.PublicKey), message, signature) {
		return errors.New("control broker: challenge signature verification failed")
	}
	return nil
}

func (b *Broker) Connect(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("X-CC-Contract-Hash") != runtimeprotocol.ContractHash {
		writeJSON(w, http.StatusUpgradeRequired, false, nil, "update_required")
		return
	}
	deviceID := strings.TrimSpace(r.URL.Query().Get("device_id"))
	challengeValue := strings.TrimSpace(r.Header.Get("X-CC-Challenge"))
	signature := strings.TrimSpace(r.Header.Get("X-CC-Signature"))
	if err := b.authenticate(r.Context(), deviceID, challengeValue, signature); err != nil {
		writeJSON(w, http.StatusUnauthorized, false, nil, err.Error())
		return
	}

	generation, err := b.nextGeneration(r.Context(), deviceID)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, false, nil, err.Error())
		return
	}
	header := http.Header{"X-CC-Connection-Generation": []string{fmt.Sprint(generation)}}
	conn, err := runtimeUpgrader.Upgrade(w, r, header)
	if err != nil {
		slog.Warn("runtime websocket upgrade failed", "device_id", deviceID, "error", err)
		return
	}
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		_ = conn.Close()
		return
	}
	b.mu.Unlock()
	runtimeConn := &runtimeConnection{deviceID: deviceID, generation: generation, conn: conn, pending: make(map[string]chan runtimeprotocol.Envelope), closed: make(chan struct{})}
	b.mu.Lock()
	previous := b.connections[deviceID]
	b.connections[deviceID] = runtimeConn
	b.mu.Unlock()
	if previous != nil {
		previous.close(errors.New("replaced by a new device connection"))
	}
	_ = b.store.TouchDevice(context.Background(), deviceID)
	_ = b.store.RecordAudit(context.Background(), "runtime:"+deviceID, "runtime_connected", "device:"+deviceID, "succeeded", nil)
	go b.readLoop(runtimeConn)
	go b.refreshCatalog(runtimeConn)
}

func (b *Broker) nextGeneration(ctx context.Context, deviceID string) (uint64, error) {
	checkpoint, err := b.store.RuntimeCheckpoint(ctx, deviceID)
	if err != nil {
		return 0, fmt.Errorf("control broker: read runtime checkpoint: %w", err)
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return 0, errors.New("control broker: closed")
	}
	if checkpoint != nil && checkpoint.ConnectionGeneration > b.generations[deviceID] {
		b.generations[deviceID] = checkpoint.ConnectionGeneration
	}
	b.generations[deviceID]++
	return b.generations[deviceID], nil
}

var runtimeUpgrader = websocket.Upgrader{
	HandshakeTimeout: 10 * time.Second,
	CheckOrigin: func(r *http.Request) bool {
		return r.Header.Get("Origin") == ""
	},
}

func (b *Broker) readLoop(connection *runtimeConnection) {
	defer b.removeConnection(connection)
	for {
		_, raw, err := connection.conn.ReadMessage()
		if err != nil {
			connection.close(err)
			return
		}
		envelope, err := runtimeprotocol.Decode(raw)
		if err != nil {
			connection.close(err)
			return
		}
		if envelope.DeviceID != connection.deviceID || envelope.ConnectionGeneration != connection.generation {
			connection.close(errors.New("runtime envelope identity does not match authenticated connection"))
			return
		}
		if err := connection.recvGuard.Accept(envelope); err != nil {
			connection.close(err)
			return
		}
		_ = b.store.TouchDevice(context.Background(), connection.deviceID)
		if envelope.RequestID != "" {
			connection.pendingMu.Lock()
			waiter := connection.pending[envelope.RequestID]
			delete(connection.pending, envelope.RequestID)
			connection.pendingMu.Unlock()
			if waiter != nil {
				waiter <- envelope
				close(waiter)
			}
		} else {
			if envelope.Method == runtimeprotocol.MethodProjectChanged {
				if err := b.persistCatalog(connection.deviceID, envelope.Payload); err != nil {
					connection.close(err)
					return
				}
			}
			b.publishRuntimeEvent(envelope)
		}
		if err := b.store.SaveRuntimeCheckpoint(context.Background(), connection.deviceID, connection.generation, envelope.Sequence); err != nil {
			connection.close(err)
			return
		}
		payload, err := runtimeprotocol.MarshalPayload(runtimeprotocol.Acknowledgement{ConfirmedSequence: envelope.Sequence})
		if err != nil {
			connection.close(err)
			return
		}
		if err := connection.write(runtimeprotocol.Envelope{Method: runtimeprotocol.MethodAcknowledge, Payload: payload}); err != nil {
			connection.close(err)
			return
		}
	}
}

func (b *Broker) publishRuntimeEvent(envelope runtimeprotocol.Envelope) {
	if envelope.Resource.ProjectRef != "" {
		entry, err := b.store.ResolveLocalWorkspaceReference(context.Background(), envelope.DeviceID, envelope.Resource.ProjectRef)
		if err != nil {
			slog.Warn("runtime event workspace reference rejected", "device_id", envelope.DeviceID, "error", err)
			return
		}
		envelope.Resource.ProjectRef = entry.GlobalRef
	}
	b.mu.RLock()
	subscribers := make(map[uint64]*eventSubscription, len(b.eventSubs))
	for id, subscriber := range b.eventSubs {
		subscribers[id] = subscriber
	}
	b.mu.RUnlock()
	for id, subscriber := range subscribers {
		if subscriber.publish(envelope) {
			continue
		}
		b.mu.Lock()
		if b.eventSubs[id] == subscriber {
			delete(b.eventSubs, id)
		}
		b.mu.Unlock()
	}
}

func (b *Broker) SubscribeEvents() (<-chan runtimeprotocol.Envelope, func()) {
	b.mu.Lock()
	b.nextEventSub++
	id := b.nextEventSub
	subscriber := &eventSubscription{events: make(chan runtimeprotocol.Envelope, 256)}
	b.eventSubs[id] = subscriber
	b.mu.Unlock()
	var once sync.Once
	return subscriber.events, func() {
		once.Do(func() {
			b.mu.Lock()
			if b.eventSubs[id] == subscriber {
				delete(b.eventSubs, id)
			}
			b.mu.Unlock()
			subscriber.close()
		})
	}
}

func (b *Broker) removeConnection(connection *runtimeConnection) {
	b.mu.Lock()
	removed := false
	if b.connections[connection.deviceID] == connection {
		delete(b.connections, connection.deviceID)
		removed = true
	}
	b.mu.Unlock()
	if removed {
		_ = b.store.RecordAudit(context.Background(), "runtime:"+connection.deviceID, "runtime_disconnected", "device:"+connection.deviceID, "succeeded", nil)
	}
}

func (c *runtimeConnection) close(cause error) {
	c.closeOnce.Do(func() {
		if c.conn != nil {
			_ = c.conn.Close()
		}
		close(c.closed)
		c.pendingMu.Lock()
		for id, waiter := range c.pending {
			waiter <- runtimeprotocol.Envelope{Error: &runtimeprotocol.RPCError{Code: "connection_lost", Message: cause.Error()}}
			close(waiter)
			delete(c.pending, id)
		}
		c.pendingMu.Unlock()
	})
}

func (b *Broker) RevokeDevice(ctx context.Context, deviceID string) error {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return errors.New("control broker: device_id is required")
	}
	if err := b.store.RevokeDevice(ctx, deviceID); err != nil {
		return err
	}
	b.mu.Lock()
	connection := b.connections[deviceID]
	delete(b.connections, deviceID)
	b.mu.Unlock()
	if connection != nil {
		connection.close(errors.New("device revoked"))
	}
	_ = b.store.RecordAudit(context.Background(), "admin", "device_revoked", "device:"+deviceID, "succeeded", nil)
	return nil
}

func (c *runtimeConnection) write(envelope runtimeprotocol.Envelope) error {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	c.sendSeq++
	envelope.ContractHash = runtimeprotocol.ContractHash
	envelope.DeviceID = c.deviceID
	envelope.ConnectionGeneration = c.generation
	envelope.Sequence = c.sendSeq
	return c.conn.WriteJSON(envelope)
}

func (b *Broker) Call(ctx context.Context, deviceID string, method runtimeprotocol.Method, resource runtimeprotocol.Resource, payload json.RawMessage) (json.RawMessage, error) {
	b.mu.RLock()
	connection := b.connections[deviceID]
	b.mu.RUnlock()
	if connection == nil {
		return nil, errors.New("device_offline")
	}
	requestID, err := secureToken(18)
	if err != nil {
		return nil, err
	}
	waiter := make(chan runtimeprotocol.Envelope, 1)
	connection.pendingMu.Lock()
	connection.pending[requestID] = waiter
	connection.pendingMu.Unlock()

	envelope := runtimeprotocol.Envelope{
		RequestID: requestID, Method: method, Resource: resource, Payload: payload,
	}
	err = connection.write(envelope)
	if err != nil {
		connection.pendingMu.Lock()
		delete(connection.pending, requestID)
		connection.pendingMu.Unlock()
		connection.close(err)
		return nil, fmt.Errorf("control broker: send runtime request: %w", err)
	}
	select {
	case response := <-waiter:
		if response.Error != nil {
			return nil, fmt.Errorf("runtime %s: %s", response.Error.Code, response.Error.Message)
		}
		return response.Payload, nil
	case <-ctx.Done():
		connection.pendingMu.Lock()
		delete(connection.pending, requestID)
		connection.pendingMu.Unlock()
		return nil, ctx.Err()
	case <-connection.closed:
		return nil, errors.New("device_offline")
	}
}

func (b *Broker) refreshCatalog(connection *runtimeConnection) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	raw, err := b.Call(ctx, connection.deviceID, runtimeprotocol.MethodProjectList, runtimeprotocol.Resource{}, nil)
	if err != nil {
		slog.Warn("runtime catalog refresh failed", "device_id", connection.deviceID, "error", err)
		return
	}
	if err := b.persistCatalog(connection.deviceID, raw); err != nil {
		slog.Warn("runtime catalog response invalid", "device_id", connection.deviceID, "error", err)
	}
}

func (b *Broker) persistCatalog(deviceID string, raw []byte) error {
	var catalog runtimeprotocol.ProjectCatalog
	if err := strictJSON(raw, &catalog); err != nil {
		return err
	}
	entries := make([]controlstore.CatalogEntry, 0, len(catalog.Projects))
	for _, project := range catalog.Projects {
		if strings.TrimSpace(project.LocalRef) == "" {
			continue
		}
		publicPayload, err := json.Marshal(project)
		if err != nil {
			continue
		}
		entries = append(entries, controlstore.CatalogEntry{
			DeviceID: deviceID, LocalRef: project.LocalRef,
			GlobalRef: b.workspaceRef(deviceID, project.LocalRef), Payload: publicPayload,
			Available: project.Available, Reason: project.Reason,
		})
	}
	if err := b.store.ReplaceDeviceCatalog(context.Background(), deviceID, entries); err != nil {
		return fmt.Errorf("control broker: persist runtime catalog: %w", err)
	}
	return nil
}

func (b *Broker) workspaceRef(deviceID, localRef string) string {
	mac := hmac.New(sha256.New, b.workspaceKey)
	_, _ = mac.Write([]byte(deviceID))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write([]byte(localRef))
	return "ws_" + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (b *Broker) Devices(ctx context.Context) ([]DeviceStatus, error) {
	devices, err := b.store.ListDevices(ctx)
	if err != nil {
		return nil, err
	}
	b.mu.RLock()
	defer b.mu.RUnlock()
	result := make([]DeviceStatus, 0, len(devices))
	for _, device := range devices {
		_, online := b.connections[device.ID]
		result = append(result, DeviceStatus{Device: device, Online: online && device.RevokedAt == nil})
	}
	return result, nil
}

func (b *Broker) Catalog(ctx context.Context) ([]CatalogWorkspace, error) {
	entries, err := b.store.ListCatalog(ctx)
	if err != nil {
		return nil, err
	}
	devices, err := b.Devices(ctx)
	if err != nil {
		return nil, err
	}
	byID := make(map[string]DeviceStatus, len(devices))
	for _, device := range devices {
		byID[device.ID] = device
	}
	result := make([]CatalogWorkspace, 0, len(entries))
	for _, entry := range entries {
		var project runtimeprotocol.Project
		if err := strictJSON(entry.Payload, &project); err != nil {
			return nil, fmt.Errorf("control broker: corrupt catalog entry %s: %w", entry.GlobalRef, err)
		}
		device := byID[entry.DeviceID]
		result = append(result, CatalogWorkspace{
			Ref: entry.GlobalRef, DeviceID: entry.DeviceID, DeviceName: device.Name,
			ProjectID: project.ProjectID, ProjectName: project.ProjectName,
			HostID: project.HostID, Kind: project.Kind, Git: project.Git,
			RootName: project.ProjectName, Available: project.Available && device.Online,
			Reason: offlineReason(project, device.Online), Order: project.Order, Online: device.Online, UpdatedAt: entry.UpdatedAt,
		})
	}
	return result, nil
}

func offlineReason(project runtimeprotocol.Project, online bool) string {
	if !online {
		return "设备离线，目录仅可只读查看"
	}
	return project.Reason
}

func (b *Broker) ResolveAndCall(ctx context.Context, request runtimeprotocol.InternalRequest) (json.RawMessage, error) {
	deviceID := request.DeviceID
	resource := request.Resource
	if resource.ProjectRef != "" {
		entry, err := b.store.ResolveWorkspaceReference(ctx, resource.ProjectRef)
		if err != nil {
			return nil, err
		}
		if deviceID != "" && deviceID != entry.DeviceID {
			return nil, errors.New("control broker: workspace reference belongs to another device")
		}
		deviceID = entry.DeviceID
		resource.ProjectRef = entry.LocalRef
	}
	if deviceID == "" {
		return nil, errors.New("control broker: device_id is required")
	}
	return b.Call(ctx, deviceID, request.Method, resource, request.Payload)
}

func (b *Broker) Close() error {
	b.mu.Lock()
	b.closed = true
	connections := make([]*runtimeConnection, 0, len(b.connections))
	for _, connection := range b.connections {
		connections = append(connections, connection)
	}
	b.connections = make(map[string]*runtimeConnection)
	subscribers := make([]*eventSubscription, 0, len(b.eventSubs))
	for id, subscriber := range b.eventSubs {
		subscribers = append(subscribers, subscriber)
		delete(b.eventSubs, id)
	}
	b.mu.Unlock()
	for _, subscriber := range subscribers {
		subscriber.close()
	}
	for _, connection := range connections {
		connection.close(errors.New("control broker closed"))
	}
	return nil
}

func strictJSON(raw []byte, target any) error {
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("control broker: trailing JSON is not allowed")
	}
	return nil
}

func secureToken(size int) (string, error) {
	raw := make([]byte, size)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}
