package runtimeclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/shusfun/cc-connect/core"
	"github.com/shusfun/cc-connect/runtimeprotocol"
)

type Dependencies struct {
	Agent   core.Agent
	Updater RuntimeUpdater
}

type RuntimeUpdater interface {
	Stage(context.Context, string) error
	Activate(context.Context, string) error
	Confirm(context.Context, string) error
}

type Handler struct{ dependencies Dependencies }

func NewHandler(dependencies Dependencies) (*Handler, error) {
	if dependencies.Agent == nil {
		return nil, errors.New("runtime handler: authoritative agent is required")
	}
	if _, ok := dependencies.Agent.(core.AgentProjectCatalog); !ok {
		return nil, errors.New("runtime handler: agent project catalog is required")
	}
	if _, ok := dependencies.Agent.(core.AgentSessionReader); !ok {
		return nil, errors.New("runtime handler: legacy task reader is required")
	}
	if _, ok := dependencies.Agent.(core.AgentSessionPageLister); !ok {
		return nil, errors.New("runtime handler: paged task catalog is required")
	}
	if _, ok := dependencies.Agent.(core.AgentTaskReader); !ok {
		return nil, errors.New("runtime handler: typed task reader is required")
	}
	return &Handler{dependencies: dependencies}, nil
}

func (h *Handler) SetEventEmitter(func(runtimeprotocol.Method, runtimeprotocol.Resource, json.RawMessage) error) {
}
func (h *Handler) ReleaseConnection() {}
func (h *Handler) Close()             {}

func (h *Handler) Handle(ctx context.Context, method runtimeprotocol.Method, resource runtimeprotocol.Resource, payload json.RawMessage) (json.RawMessage, error) {
	agent := h.dependencies.Agent
	switch method {
	case runtimeprotocol.MethodProjectList:
		return h.CatalogSnapshot(ctx)
	case runtimeprotocol.MethodTaskList:
		request := runtimeprotocol.TaskListRequest{}
		if len(payload) > 0 {
			var err error
			request, err = decodePayload[runtimeprotocol.TaskListRequest](payload)
			if err != nil {
				return nil, err
			}
		}
		if resource.ProjectRef != "" {
			if request.ProjectID != "" && request.ProjectID != resource.ProjectRef {
				return nil, errors.New("runtime handler: task project does not match the authorized resource")
			}
			request.ProjectID = resource.ProjectRef
		}
		result, err := agent.(core.AgentSessionPageLister).ListSessionPage(ctx, core.AgentSessionListRequest{
			ProjectID: request.ProjectID, Cursor: request.Cursor, Limit: request.Limit,
		})
		return encodeResult(result, err)
	case runtimeprotocol.MethodTaskRead:
		request, err := decodePayload[runtimeprotocol.TaskReadRequest](payload)
		if err != nil {
			return nil, err
		}
		result, err := agent.(core.AgentTaskReader).ReadTask(ctx, request.TaskID, request.HostID, request.Cursor, request.Limit)
		return encodeResult(result, err)
	case runtimeprotocol.MethodTaskWait:
		waiter, ok := agent.(core.AgentTaskWaiter)
		if !ok {
			return nil, errors.New("runtime handler: authoritative task wait is unavailable")
		}
		request, err := decodePayload[runtimeprotocol.TaskWaitRequest](payload)
		if err != nil {
			return nil, err
		}
		result, err := waiter.WaitTask(ctx, request.TaskID, request.HostID, request.Cursor, time.Duration(request.TimeoutMS)*time.Millisecond)
		return encodeResult(result, err)
	case runtimeprotocol.MethodTaskCreate:
		creator, ok := agent.(core.AgentSessionCreator)
		if !ok {
			return nil, errors.New("runtime handler: task creation is unavailable")
		}
		request, err := decodePayload[core.AgentSessionCreateRequest](payload)
		if err != nil {
			return nil, err
		}
		if resource.ProjectRef != "" {
			if request.ProjectID != "" && request.ProjectID != resource.ProjectRef {
				return nil, errors.New("runtime handler: task project does not match the authorized resource")
			}
			request.ProjectID = resource.ProjectRef
		}
		result, err := creator.CreateSession(ctx, request)
		return encodeResult(result, err)
	case runtimeprotocol.MethodTaskMetadata:
		controller, ok := agent.(core.AgentSessionMetadataController)
		if !ok {
			return nil, errors.New("runtime handler: task metadata control is unavailable")
		}
		request, err := decodePayload[struct {
			TaskID string                         `json:"task_id"`
			HostID string                         `json:"host_id,omitempty"`
			Patch  core.AgentSessionMetadataPatch `json:"patch"`
		}](payload)
		if err != nil {
			return nil, err
		}
		return encodeResult(struct{}{}, controller.UpdateSessionMetadata(ctx, request.TaskID, request.HostID, request.Patch))
	case runtimeprotocol.MethodCapabilityList:
		catalog, ok := agent.(core.AgentSessionCapabilityCatalog)
		if !ok {
			return nil, errors.New("runtime handler: task capability catalog is unavailable")
		}
		result, err := catalog.SessionCapabilities(ctx, "")
		return encodeResult(result, err)
	case runtimeprotocol.MethodTaskSearch:
		searcher, ok := agent.(core.AgentTaskSearcher)
		if !ok {
			return nil, errors.New("runtime handler: task search is unavailable")
		}
		request, err := decodePayload[runtimeprotocol.TaskSearchRequest](payload)
		if err != nil {
			return nil, err
		}
		result, err := searcher.SearchTasks(ctx, core.AgentTaskSearchRequest{Query: request.Query, Limit: request.Limit})
		return encodeResult(result, err)
	case runtimeprotocol.MethodTaskArchived:
		lister, ok := agent.(core.AgentArchivedTaskLister)
		if !ok {
			return nil, errors.New("runtime handler: archived tasks are unavailable")
		}
		request := runtimeprotocol.TaskListRequest{}
		if len(payload) > 0 {
			var err error
			request, err = decodePayload[runtimeprotocol.TaskListRequest](payload)
			if err != nil {
				return nil, err
			}
		}
		result, err := lister.ListArchivedTasks(ctx, request.Limit)
		return encodeResult(result, err)
	case runtimeprotocol.MethodAutomationList:
		controller, ok := agent.(core.AgentAutomationController)
		if !ok {
			return nil, errors.New("runtime handler: automations are unavailable")
		}
		result, err := controller.ListAutomations(ctx)
		return encodeResult(result, err)
	case runtimeprotocol.MethodAutomationCreate, runtimeprotocol.MethodAutomationUpdate:
		controller, ok := agent.(core.AgentAutomationController)
		if !ok {
			return nil, errors.New("runtime handler: automations are unavailable")
		}
		request, err := decodePayload[core.AgentAutomationMutation](payload)
		if err != nil {
			return nil, err
		}
		if method == runtimeprotocol.MethodAutomationCreate {
			result, err := controller.CreateAutomation(ctx, request)
			return encodeResult(result, err)
		}
		result, err := controller.UpdateAutomation(ctx, request)
		return encodeResult(result, err)
	case runtimeprotocol.MethodAutomationDelete:
		controller, ok := agent.(core.AgentAutomationController)
		if !ok {
			return nil, errors.New("runtime handler: automations are unavailable")
		}
		request, err := decodePayload[runtimeprotocol.AutomationDeleteRequest](payload)
		if err != nil {
			return nil, err
		}
		return encodeResult(struct{}{}, controller.DeleteAutomation(ctx, request.ID))
	case runtimeprotocol.MethodPluginList:
		controller, ok := agent.(core.AgentPluginController)
		if !ok {
			return nil, errors.New("runtime handler: plugins are unavailable")
		}
		request, err := decodePayload[runtimeprotocol.PluginListRequest](payload)
		if err != nil {
			return nil, err
		}
		result, err := controller.ListPlugins(ctx, request.Available)
		return encodeResult(result, err)
	case runtimeprotocol.MethodPluginInstall, runtimeprotocol.MethodPluginRemove:
		controller, ok := agent.(core.AgentPluginController)
		if !ok {
			return nil, errors.New("runtime handler: plugins are unavailable")
		}
		request, err := decodePayload[runtimeprotocol.PluginMutationRequest](payload)
		if err != nil {
			return nil, err
		}
		if method == runtimeprotocol.MethodPluginInstall {
			result, err := controller.InstallPlugin(ctx, request.ID)
			return encodeResult(result, err)
		}
		return encodeResult(struct{}{}, controller.RemovePlugin(ctx, request.ID))
	case runtimeprotocol.MethodTaskSend:
		request, err := decodePayload[runtimeprotocol.TaskSendRequest](payload)
		if err != nil {
			return nil, err
		}
		return h.send(ctx, request)
	case runtimeprotocol.MethodUpdateStage, runtimeprotocol.MethodUpdateActivate, runtimeprotocol.MethodUpdateConfirm:
		return h.update(ctx, method, payload)
	default:
		return nil, fmt.Errorf("runtime handler: method %q is not a request method", method)
	}
}

func (h *Handler) send(ctx context.Context, request runtimeprotocol.TaskSendRequest) (json.RawMessage, error) {
	session, err := h.dependencies.Agent.StartSession(ctx, request.TaskID)
	if err != nil {
		return nil, err
	}
	defer func() { _ = session.Close() }()
	if target, ok := session.(core.AgentSessionHostTarget); ok {
		target.SetHostID(request.HostID)
	}
	if err := session.Send(request.Prompt, request.MessageID, nil, nil); err != nil {
		return nil, err
	}
	var output strings.Builder
	for {
		select {
		case event, ok := <-session.Events():
			if !ok {
				return nil, errors.New("runtime handler: task observation ended before completion")
			}
			if event.Error != nil {
				return nil, event.Error
			}
			if event.Type == core.EventText && event.Content != "" {
				output.WriteString(event.Content)
			}
			if event.Done {
				return encodeResult(runtimeprotocol.TaskSendResult{TaskID: session.CurrentSessionID(), Content: output.String()}, nil)
			}
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
}

func (h *Handler) update(ctx context.Context, method runtimeprotocol.Method, payload json.RawMessage) (json.RawMessage, error) {
	if h.dependencies.Updater == nil {
		return nil, errors.New("runtime handler: release updates are unavailable")
	}
	request, err := decodePayload[runtimeprotocol.RuntimeUpdateRequest](payload)
	if err != nil {
		return nil, err
	}
	switch method {
	case runtimeprotocol.MethodUpdateStage:
		err = h.dependencies.Updater.Stage(ctx, request.Tag)
	case runtimeprotocol.MethodUpdateActivate:
		err = h.dependencies.Updater.Activate(ctx, request.Tag)
	case runtimeprotocol.MethodUpdateConfirm:
		err = h.dependencies.Updater.Confirm(ctx, request.Tag)
	}
	return encodeResult(runtimeprotocol.RuntimeUpdateResult{Tag: request.Tag, Status: string(method)}, err)
}

func (h *Handler) CatalogSnapshot(ctx context.Context) (json.RawMessage, error) {
	projects, err := h.dependencies.Agent.(core.AgentProjectCatalog).ListProjects(ctx)
	if err != nil {
		return nil, err
	}
	result := runtimeprotocol.ProjectCatalog{Projects: make([]runtimeprotocol.Project, 0, len(projects))}
	for index, project := range projects {
		result.Projects = append(result.Projects, runtimeprotocol.Project{
			LocalRef: project.ID, ProjectID: project.ID, ProjectName: project.Name,
			HostID: project.HostID, Kind: project.Kind, Git: project.IsGitRepository,
			Available: true, Order: index,
		})
	}
	return encodeResult(result, nil)
}

func decodePayload[T any](payload json.RawMessage) (T, error) {
	var result T
	if len(payload) == 0 {
		return result, errors.New("runtime handler: payload is required")
	}
	decoder := json.NewDecoder(strings.NewReader(string(payload)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return result, fmt.Errorf("runtime handler: invalid payload: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return result, errors.New("runtime handler: payload contains trailing JSON")
	}
	return result, nil
}

func encodeResult(value any, err error) (json.RawMessage, error) {
	if err != nil {
		return nil, err
	}
	payload, marshalErr := json.Marshal(value)
	if marshalErr != nil {
		return nil, fmt.Errorf("runtime handler: encode response: %w", marshalErr)
	}
	return payload, nil
}
