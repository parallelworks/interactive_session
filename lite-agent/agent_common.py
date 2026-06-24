#!/usr/bin/env python3
"""Shared plumbing for the agents (lite-agent and agent-orchestrator).

Each agent is a small OpenAI-compatible HTTP server:
    GET  /v1/models            advertise this agent as one chat model
    POST /v1/chat/completions  run the agent loop (stream=true -> SSE)
    GET  / or /health          status

The "brain" is the Activate platform's OpenAI-compatible endpoint. We send it
the conversation plus the tools the agent offers; it decides which tools to
call; we run them and feed the results back; it writes the final answer. This
module holds that loop, the brain client, and the HTTP/SSE framing, so each role
only has to declare its own tools, system prompt, and any extra endpoints.

Standard library only, so it runs on a clean Python 3 (the cluster nodes ship
3.9) with nothing to install.
"""
import json
import os
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Brain = the platform OpenAI-compatible endpoint. The key is the runtime
# PW_API_KEY (the start script exports it as OPENAI_API_KEY); org:* models also
# require the X-Allocation header. None of this is persisted to disk.
BRAIN_URL = os.environ.get("OPENAI_BASE_URL", "").rstrip("/")
BRAIN_KEY = os.environ.get("OPENAI_API_KEY", "")
BRAIN_MODEL = os.environ.get("MODEL", "org:glm/glm-5.1")
ALLOCATION = os.environ.get("X_ALLOCATION", "")
BRAIN_TIMEOUT = int(os.environ.get("AGENT_BRAIN_TIMEOUT") or 300)


def brain_ready():
    return bool(BRAIN_URL and BRAIN_KEY)


def _brain_headers():
    headers = {"Authorization": "Bearer " + BRAIN_KEY, "Content-Type": "application/json"}
    if ALLOCATION:
        headers["X-Allocation"] = ALLOCATION
    return headers


def list_brain_models():
    """The models the platform endpoint exposes (GET /v1/models) -> [{id,name,..}].
    Empty on any error, so model resolution degrades to the literal id."""
    if not brain_ready():
        return []
    try:
        req = urllib.request.Request(BRAIN_URL + "/models", headers=_brain_headers())
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
        return data.get("data", []) if isinstance(data, dict) else []
    except Exception:  # noqa: BLE001 - resolution is best-effort
        return []


def resolve_brain_model(want):
    """Map a model name to the id the brain endpoint routes by.

    The platform routes by a fully-qualified id ('org:owner/provider' or
    'session:user:provider/model'); the chat model picker only shows the short
    name ('/gpt-oss-20b', 'glm-5.1'). Sending that short name fails with
    400 "Invalid provider identifier format". So when `want` has no provider
    prefix (no ':'), look it up in GET /v1/models and return the full id whose
    trailing name segment matches. Already-qualified ids (and unknown names, if
    the lookup turns up nothing) pass through unchanged."""
    want = (want or "").strip()
    if not want or ":" in want:
        return want
    tail = want.lstrip("/")  # session ids look like '..provider//gpt-oss-20b'
    models = list_brain_models()
    for m in models:
        if m.get("id") == want:
            return want
    for m in models:
        mid = m.get("id", "")
        if mid.rsplit("/", 1)[-1] == tail:
            return mid
    for m in models:  # last resort: the parenthetical display name 'provider (name)'
        name = m.get("name", "")
        if "(" in name and name.rsplit("(", 1)[-1].rstrip(")").strip().lstrip("/") == tail:
            return m.get("id", want)
    return want


_RESOLVED_MODEL = None


def brain_model():
    """The brain model id to send, resolved from the configured name and cached.
    A successful resolution (a fully-qualified id) is cached; an unresolved bare
    name is retried on the next call so it self-heals once its backing model
    (e.g. a not-yet-started session model) appears."""
    global _RESOLVED_MODEL
    if _RESOLVED_MODEL:
        return _RESOLVED_MODEL
    resolved = resolve_brain_model(BRAIN_MODEL)
    if ":" in resolved:
        if resolved != BRAIN_MODEL:
            print("brain model %r resolved to %r" % (BRAIN_MODEL, resolved), flush=True)
        _RESOLVED_MODEL = resolved
    return resolved


def call_brain(messages, tools=None):
    """One chat-completion call to the platform brain -> the reply message dict.
    Raises on transport/HTTP errors; the caller turns that into a chat error."""
    body = {"model": brain_model(), "messages": messages}
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    req = urllib.request.Request(BRAIN_URL + "/chat/completions",
                                 data=json.dumps(body).encode(), headers=_brain_headers())
    with urllib.request.urlopen(req, timeout=BRAIN_TIMEOUT) as resp:
        return json.load(resp)["choices"][0]["message"]


def _tool_args(call):
    try:
        return json.loads(call["function"].get("arguments") or "{}")
    except (ValueError, KeyError):
        return {}


def load_system_prompt(default):
    """The system prompt from the file named by AGENT_SYSTEM_PROMPT_FILE (the
    workflow form writes the user's prompt there), or `default` if that file is
    missing/empty. Kept in a file rather than inputs.sh so multi-line or quoted
    prompt text can't break the sourced shell."""
    path = os.environ.get("AGENT_SYSTEM_PROMPT_FILE", "")
    if path:
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read().strip()
        except OSError:
            text = ""
        if text:
            return text
    return default


class Agent:
    """Runs the brain over a set of tools until it produces an answer.

    tools     -- OpenAI tool schema list advertised to the brain
    run_tool  -- run_tool(name, args) executes one call, returns a JSON-able result
    describe  -- optional describe(name, args) -> short label shown as progress
    """

    def __init__(self, model_id, system, tools, run_tool, describe=None, max_steps=6):
        self.model_id = model_id
        self.system = system
        self.tools = tools
        self.run_tool = run_tool
        self.describe = describe or (lambda name, args: name)
        self.max_steps = max_steps

    def run(self, messages):
        """Generator of (kind, text) events. kind is 'step' for progress while
        tools run, or 'answer' for the final reply. Progress is streamed so the
        session tunnel keeps receiving bytes during slow tools (long silences
        can hit the proxy timeout)."""
        msgs = [{"role": "system", "content": self.system}] + list(messages)
        for _ in range(self.max_steps):
            reply = call_brain(msgs, self.tools)
            msgs.append({k: v for k, v in reply.items() if v is not None})
            calls = reply.get("tool_calls") or []
            if not calls:
                yield "answer", reply.get("content") or ""
                return
            labels = {c["id"]: self.describe(c["function"]["name"], _tool_args(c)) for c in calls}
            yield "step", "→ " + "; ".join(labels[c["id"]] for c in calls)
            results = {}
            for cid, result in self._run_calls(calls):
                results[cid] = result
                yield "step", "✓ " + labels[cid]
            for c in calls:  # feed results back in the order the brain asked for them
                msgs.append({"role": "tool", "tool_call_id": c["id"],
                             "content": json.dumps(results[c["id"]])})
        yield "answer", "Sorry — I couldn't finish within the step limit."

    def _run_calls(self, calls):
        """Run this turn's tool calls, yielding (id, result) as each finishes.
        Several calls in one turn run concurrently (e.g. ask every cluster at
        once), so the turn takes about as long as its slowest tool."""
        def one(call):
            return call["id"], self.run_tool(call["function"]["name"], _tool_args(call))
        if len(calls) == 1:
            yield one(calls[0])
            return
        with ThreadPoolExecutor(max_workers=min(16, len(calls))) as pool:
            for fut in as_completed([pool.submit(one, c) for c in calls]):
                yield fut.result()

    def answer(self, messages):
        """Run to completion and return just the final answer text."""
        final = ""
        for kind, text in self.run(messages):
            if kind == "answer":
                final = text
        return final


def _models_payload(model_ids):
    return {"object": "list", "data": [
        {"id": mid, "object": "model", "created": int(time.time()), "owned_by": "agent"}
        for mid in model_ids]}


def _completion_payload(model_id, content):
    return {"id": "chatcmpl-agent", "object": "chat.completion", "created": int(time.time()),
            "model": model_id, "choices": [
                {"index": 0, "finish_reason": "stop",
                 "message": {"role": "assistant", "content": content}}]}


def serve(model_id, route, list_models, role, port, host="0.0.0.0",
          get_routes=None, post_routes=None, status=None):
    """Start the OpenAI-compatible HTTP server for an agent.

    route(req) -> a responder (an object with .run(messages) and .answer(messages))
        chosen from the request — lets one session serve several models and send
        each to the right place (the orchestrator routes per-worker chats here).
    list_models() -> the model ids to advertise at GET /v1/models.
    get_routes / post_routes: {path-suffix: fn} for role-specific endpoints
        (fn() -> obj for GET, fn(body) -> obj for POST), returned as JSON.
    status: optional fn() -> dict merged into the / and /health page.
    """
    get_routes = get_routes or {}
    post_routes = post_routes or {}

    class Handler(BaseHTTPRequestHandler):
        # HTTP/1.1 so streamed replies use chunked transfer-encoding: the
        # terminating 0-chunk tells the platform's proxy the stream ended
        # cleanly. (HTTP/1.0 close-delimited bodies look truncated to the proxy
        # and it aborts the chat with an INTERNAL_ERROR.)
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):  # keep the service log quiet
            pass

        def _json(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.rstrip("/")
            if path.endswith("/models"):
                self._json(200, _models_payload(list_models()))
                return
            for suffix, fn in get_routes.items():
                if path.endswith(suffix):
                    self._json(200, fn())
                    return
            info = {"status": "ok", "role": role, "model": model_id, "brain": brain_ready()}
            if status:
                info.update(status())
            self._json(200, info)

        def do_POST(self):
            path = self.path.rstrip("/")
            try:
                length = int(self.headers.get("Content-Length", 0))
                req = json.loads(self.rfile.read(length) or b"{}")
            except (ValueError, TypeError) as exc:
                self._json(400, {"error": {"message": "bad request: %s" % exc}})
                return
            try:
                if path.endswith("chat/completions"):
                    self._chat(req)
                    return
                for suffix, fn in post_routes.items():
                    if path.endswith(suffix):
                        self._json(200, fn(req))
                        return
                self._json(404, {"error": {"message": "not found"}})
            except Exception as exc:  # noqa: BLE001 - surface as an API error, don't crash
                self._json(500, {"error": {"message": str(exc), "type": role + "_error"}})

        def _chat(self, req):
            responder = route(req)
            messages = req.get("messages", [])
            if req.get("stream"):
                self._chat_stream(responder, messages)
                return
            try:
                content = responder.answer(messages)
            except Exception as exc:  # noqa: BLE001
                content = "Sorry, I hit an error: %s" % exc
            self._json(200, _completion_payload(model_id, content))

        def _chat_stream(self, responder, messages):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

            lock = threading.Lock()
            done = threading.Event()

            def chunk(raw):  # one HTTP chunked-encoding frame, serialized across threads
                with lock:
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(raw), raw))
                    self.wfile.flush()

            def delta(body, finish=None):
                chunk(("data: " + json.dumps({
                    "id": "chatcmpl-agent", "object": "chat.completion.chunk",
                    "created": int(time.time()), "model": model_id,
                    "choices": [{"index": 0, "delta": body, "finish_reason": finish}]}) + "\n\n").encode())

            def keepalive():
                # Empty-content deltas every second keep bytes flowing while the
                # brain is thinking; without them the platform proxy treats the
                # idle stream as dead and resets the chat (INTERNAL_ERROR).
                while not done.wait(1.0):
                    try:
                        delta({"content": ""})
                    except OSError:
                        return
            threading.Thread(target=keepalive, daemon=True).start()

            try:
                delta({"role": "assistant"})
                for kind, text in responder.run(messages):
                    if text:
                        delta({"content": text + "\n" if kind == "step" else text})
                delta({}, "stop")
                chunk(b"data: [DONE]\n\n")
                with lock:
                    self.wfile.write(b"0\r\n\r\n")   # terminating chunk: clean end of stream
                    self.wfile.flush()
            except OSError:
                pass   # client disconnected mid-stream
            except Exception as exc:  # noqa: BLE001 - surface brain/tool errors in the chat
                try:
                    delta({"content": "\n[error: %s]" % exc})
                    delta({}, "stop")
                    chunk(b"data: [DONE]\n\n")
                except OSError:
                    pass
            finally:
                done.set()

    print("agent %s (OpenAI-compatible) on %s:%s as model '%s' | brain=%s"
          % (role, host, port, model_id, brain_ready()), flush=True)
    ThreadingHTTPServer((host, port), Handler).serve_forever()
