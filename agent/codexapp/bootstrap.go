package codexapp

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/term"
)

const bridgeWorkerFDEnv = "CC_CONNECT_CODEXAPP_BRIDGE_FD"

const bootstrapRelayScript = `
const fs = require("fs");
const net = require("net");
const { randomUUID } = require("crypto");
const { spawn } = require("child_process");
const MAX_FRAME_BYTES = 8 * 1024 * 1024;
const REQUIRED_TOOLS = ["create_thread", "list_projects", "list_threads", "read_thread", "send_message_to_thread", "wait_threads"];
const explicitPath = process.argv[1];
const workerExecutable = process.env.CC_CONNECT_RUNTIME_EXECUTABLE;
const workerArgs = JSON.parse(process.env.CC_CONNECT_RUNTIME_ARGS || "[]");
const contextThreadId = process.env.CODEX_THREAD_ID;
let worker = null;
let activeSocket = null;
let stoppingWorker = false;
let stopped = false;
let lastRelayError = "";
let lastRelayErrorAt = 0;

function frame(value) {
  const payload = Buffer.from(JSON.stringify(value), "utf8");
  if (payload.length > MAX_FRAME_BYTES) throw new Error("request exceeds 8 MiB");
  const result = Buffer.alloc(4 + payload.length);
  result.writeUInt32LE(payload.length, 0);
  payload.copy(result, 4);
  return result;
}

function candidatePaths() {
  if (explicitPath && fs.existsSync(explicitPath)) return [explicitPath];
  const directory = "/tmp/codex-browser-use";
  let entries = [];
  try { entries = fs.readdirSync(directory); } catch { return []; }
  return entries.filter(name => name.endsWith(".sock")).map(name => directory + "/" + name).filter(path => {
    try {
      const stat = fs.lstatSync(path);
      return stat.isSocket() && stat.uid === process.getuid();
    } catch { return false; }
  }).sort();
}

function probe(path) {
  return new Promise(resolve => {
	const probeToken = randomUUID();
	const toolsProbeId = 1;
	const projectsProbeId = 2;
    const socket = net.connect(path);
    let pending = Buffer.alloc(0);
    let settled = false;
    const timer = setTimeout(() => finish("probe timed out"), 3000);
    function finish(error) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.off("data", onData);
      socket.off("error", onFailure);
      socket.off("close", onFailure);
      if (error) socket.destroy();
      else socket.pause();
      resolve({path, error, socket: error ? null : socket});
    }
    function onFailure(error) { finish(error?.message || "socket closed during probe"); }
    function onData(chunk) {
      pending = Buffer.concat([pending, chunk]);
      while (pending.length >= 4) {
        const size = pending.readUInt32LE(0);
        if (size > MAX_FRAME_BYTES) return finish("response exceeds 8 MiB");
        if (pending.length < size + 4) return;
        const payload = pending.subarray(4, size + 4);
        pending = pending.subarray(size + 4);
        let response;
        try { response = JSON.parse(payload.toString("utf8")); } catch { return finish("response is not valid JSON"); }
		if (response.id === toolsProbeId) {
          if (response.error) return finish("tools/list rpc error " + response.error.code + ": " + response.error.message);
          const tools = response.result?.tools;
          if (!Array.isArray(tools)) return finish("tools/list returned no tool catalog");
          const missing = REQUIRED_TOOLS.filter(name => !tools.some(tool => tool.name === name));
          if (missing.length > 0) return finish("tools/list missing required capabilities: " + missing.join(", "));
          const projectTool = tools.find(tool => tool.name === "list_projects");
          if (!contextThreadId) return finish("CODEX_THREAD_ID is unavailable");
          if (!projectTool?.namespace) return finish("list_projects namespace is unavailable");
		  socket.write(frame({jsonrpc:"2.0", id:projectsProbeId, method:"tools/call", params:{
			arguments:{}, callId:"cc-connect-call-" + probeToken, namespace:projectTool.namespace,
			threadId:contextThreadId, tool:"list_projects", turnId:"cc-connect-turn-" + probeToken
		  }}));
		} else if (response.id === projectsProbeId) {
          if (response.error) return finish("list_projects rpc error " + response.error.code + ": " + response.error.message);
          if (response.result?.success !== true) {
            const detail = (response.result?.contentItems || []).filter(item => item.type === "inputText").map(item => item.text).join(" ").slice(0, 500);
            return finish("list_projects failed" + (detail ? ": " + detail : ""));
          }
		  finish("");
        }
      }
    }
    socket.on("data", onData);
    socket.once("error", onFailure);
    socket.once("close", onFailure);
	socket.once("connect", () => socket.write(frame({
	  jsonrpc:"2.0", id:toolsProbeId, method:"tools/list", params:{threadStartKind:"all"}
    })));
  });
}

async function selectSocket() {
  const paths = candidatePaths();
  if (paths.length === 0) throw new Error("no current-UID Desktop App tools socket found");
  const results = await Promise.all(paths.map(probe));
  const active = results.filter(result => !result.error);
  if (active.length === 1) return active[0].socket;
  if (active.length > 1) {
    active.forEach(result => result.socket.destroy());
    throw new Error("multiple active Desktop App tools sockets are ambiguous: " + active.map(result => result.path).join(", "));
  }
  throw new Error("no active Desktop App tools socket passed probes: " + results.map(result => result.path + ": " + result.error).join("; "));
}

function reportRelayError(error) {
  const message = error?.message || String(error);
  const now = Date.now();
  if (message !== lastRelayError || now - lastRelayErrorAt >= 30000) {
    console.error("cc-connect Codex App relay: " + message);
    lastRelayError = message;
    lastRelayErrorAt = now;
  }
}

function stopWorker() {
  return new Promise(resolve => {
    if (worker == null) return resolve();
    const current = worker;
    stoppingWorker = true;
    const timer = setTimeout(() => current.kill("SIGKILL"), 2000);
    current.once("exit", () => {
      clearTimeout(timer);
      if (worker === current) worker = null;
      stoppingWorker = false;
      resolve();
    });
    current.kill("SIGTERM");
  });
}

async function startGeneration() {
  while (!stopped) {
    try {
      activeSocket = await selectSocket();
      lastRelayError = "";
      lastRelayErrorAt = 0;
      const environment = {...process.env, CC_CONNECT_CODEXAPP_BRIDGE_FD:"3"};
      worker = spawn(workerExecutable, workerArgs, {env:environment, stdio:["ignore","inherit","inherit","pipe"]});
      const control = worker.stdio[3];
      control.pipe(activeSocket);
      activeSocket.pipe(control);
      activeSocket.once("close", async () => {
        if (stopped) return;
        activeSocket = null;
        await stopWorker();
        setTimeout(startGeneration, 250);
      });
      worker.once("exit", code => {
        if (!stoppingWorker && !stopped) process.exit(code == null ? 1 : code);
      });
      return;
    } catch (error) {
      reportRelayError(error);
      await new Promise(resolve => setTimeout(resolve, 2000));
    }
  }
}

async function shutdown() {
  if (stopped) return;
  stopped = true;
  activeSocket?.destroy();
  await stopWorker();
  process.exit(0);
}

process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
startGeneration();
`

func InheritedBridgeFD() (int, error) {
	value := strings.TrimSpace(os.Getenv(bridgeWorkerFDEnv))
	if value == "" {
		return 0, nil
	}
	fd, err := strconv.Atoi(value)
	if err != nil || fd < 3 {
		return 0, fmt.Errorf("codex app bridge: invalid inherited relay fd %q", value)
	}
	return fd, nil
}

func BootstrapRuntime(socketPath, explicitNodePath string, args []string) error {
	if !term.IsTerminal(int(os.Stdin.Fd())) || !term.IsTerminal(int(os.Stdout.Fd())) {
		return errors.New("codex app bridge: cc-connect-runtime must be started from an interactive Codex App terminal")
	}
	if strings.TrimSpace(socketPath) != "" {
		if err := validateOwnedSocket(socketPath); err != nil {
			return err
		}
	}
	if strings.TrimSpace(os.Getenv("CODEX_THREAD_ID")) == "" {
		return errors.New("codex app bridge: CODEX_THREAD_ID is required from the current Codex App terminal")
	}
	nodePath, err := desktopNodePath(explicitNodePath)
	if err != nil {
		return err
	}
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("codex app bridge: locate Runtime executable: %w", err)
	}
	encodedArgs, err := json.Marshal(args)
	if err != nil {
		return fmt.Errorf("codex app bridge: encode Runtime arguments: %w", err)
	}
	environment := replaceEnv(os.Environ(), "CODEX_APP_TOOLS_PIPE_PATH", socketPath)
	environment = replaceEnv(environment, "CC_CONNECT_RUNTIME_EXECUTABLE", executable)
	environment = replaceEnv(environment, "CC_CONNECT_RUNTIME_ARGS", string(encodedArgs))
	if err := syscall.Exec(nodePath, []string{nodePath, "-e", bootstrapRelayScript, socketPath}, environment); err != nil {
		return fmt.Errorf("codex app bridge: exec Desktop relay: %w", err)
	}
	return nil
}

func desktopNodePath(explicit string) (string, error) {
	paths := []string{
		strings.TrimSpace(explicit), strings.TrimSpace(os.Getenv("CODEX_APP_NODE_PATH")),
		"/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node",
		"/Applications/Codex.app/Contents/Resources/cua_node/bin/node",
	}
	for _, path := range paths {
		if path == "" {
			continue
		}
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path, nil
		}
	}
	return "", errors.New("codex app bridge: signed Desktop App Node runtime was not found")
}

func replaceEnv(environment []string, key, value string) []string {
	prefix := key + "="
	result := make([]string, 0, len(environment)+1)
	for _, item := range environment {
		if !strings.HasPrefix(item, prefix) {
			result = append(result, item)
		}
	}
	return append(result, prefix+value)
}
