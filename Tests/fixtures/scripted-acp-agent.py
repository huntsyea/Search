#!/usr/bin/env python3
"""A scripted ACP agent for Search's tests.

Usage: scripted-acp-agent.py <scenario.json> <log.jsonl>

Talks ACP (JSON-RPC 2.0, one JSON object per line) on stdin and stdout, and
does what the scenario says. Every message it receives is appended to the log
as one JSON line, and what an MCP tool call answers as {"mcpResult": ...}.
"""

import json
import os
import queue
import subprocess
import sys
import threading
import time


class Gone(Exception):
    """stdin closed: the agent's own input is done."""


class Log:
    """The log's lines, written whole and flushed, from either thread."""

    def __init__(self, path):
        self.lock = threading.Lock()
        self.file = open(path, "a")

    def line(self, message):
        with self.lock:
            self.file.write(json.dumps(message) + "\n")
            self.file.flush()


DEFAULT_INITIALIZE = {
    "protocolVersion": 1,
    "agentCapabilities": {
        "loadSession": True,
        "mcpCapabilities": {"http": False, "sse": False},
        "promptCapabilities": {},
    },
    "authMethods": [],
    "agentInfo": {"name": "scripted", "version": "1"},
}


class Scripted:
    def __init__(self, scenario, log):
        self.scenario = scenario
        self.log = log
        self.queue = queue.Queue()
        self.deferred = []
        self.cancelled = False
        self.prompt_index = 0
        self.agent_id = 0
        self.mcp_server = None
        self.mcp = None
        self.mcp_id = 0
        # Sign-in: the methods initialize lists, and which one counts as done.
        self.auth = scenario.get("auth")
        self.signed_in = False
        # So a test can tell when the process is gone.
        self.log.line({"pid": os.getpid()})

    # ----- transport -----

    def reader(self):
        for raw in sys.stdin:
            text = raw.strip()
            if not text:
                continue
            try:
                message = json.loads(text)
            except ValueError:
                continue
            self.log.line(message)
            self.queue.put(message)
        self.queue.put(None)

    def send(self, message):
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()

    def next_message(self, timeout=None):
        try:
            message = self.queue.get(timeout=timeout)
        except queue.Empty:
            return "timeout"
        if message is None:
            raise Gone()
        return message

    def answer(self, rid, result):
        self.send({"jsonrpc": "2.0", "id": rid, "result": result})

    def fail(self, rid, code, message):
        self.send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    # ----- the loop -----

    def run(self):
        try:
            while True:
                message = self.deferred.pop(0) if self.deferred else self.next_message()
                if message == "timeout":
                    continue
                self.handle(message)
        except Gone:
            pass
        finally:
            self.cleanup()
        return 0

    def handle(self, message):
        if "method" in message:
            if "id" in message:
                self.handle_request(message)
            else:
                self.handle_notification(message)
        # a response to nothing we are waiting on: ignored

    def handle_notification(self, message):
        if message.get("method") == "session/cancel":
            self.cancelled = True

    def handle_request(self, message):
        method = message.get("method")
        rid = message.get("id")
        params = message.get("params") or {}
        if method == "initialize":
            result = dict(self.scenario.get("initialize", DEFAULT_INITIALIZE))
            if self.auth:
                result["authMethods"] = self.auth.get("methods", [])
            self.answer(rid, result)
        elif method == "authenticate":
            if self.auth and params.get("methodId") == self.auth.get("accept"):
                self.signed_in = True
                self.answer(rid, {})
            else:
                self.fail(rid, -32000, "Wrong method")
        elif method == "session/new":
            if self.auth and not self.signed_in:
                self.fail(rid, -32000, "Authentication required")
                return
            self.remember_mcp(params)
            spec = self.scenario.get("new", {"sessionId": "s-1"})
            if spec.get("hang"):
                return
            if "error" in spec:
                self.send({"jsonrpc": "2.0", "id": rid, "error": spec["error"]})
            else:
                self.answer(rid, spec)
        elif method == "session/load":
            if self.auth and not self.signed_in:
                self.fail(rid, -32000, "Authentication required")
                return
            self.remember_mcp(params)
            spec = self.scenario.get("load", {})
            if "error" in spec:
                self.send({"jsonrpc": "2.0", "id": rid, "error": spec["error"]})
            else:
                for update in spec.get("updates", []):
                    self.update(params.get("sessionId"), update)
                self.answer(rid, spec.get("result", {}))
        elif method == "session/prompt":
            self.handle_prompt(rid, params)
        elif method == "session/set_config_option":
            spec = self.scenario.get("setConfig", {"configOptions": []})
            if spec.get("hang"):
                return
            self.answer(rid, spec)
        elif method == "session/set_model":
            self.answer(rid, self.scenario.get("setModel", {}))
        else:
            self.fail(rid, -32601, "Method not found")

    def handle_prompt(self, rid, params):
        session = params.get("sessionId")
        prompts = self.scenario.get("prompts", [])
        steps = prompts[self.prompt_index] if self.prompt_index < len(prompts) else []
        self.prompt_index += 1
        for step in steps:
            if "update" in step:
                self.update(session, step["update"])
            elif "ask" in step:
                ask = step["ask"]
                self.wait_for_response(self.ask("session/request_permission", {
                    "sessionId": session,
                    "toolCall": ask.get("toolCall", {}),
                    "options": ask.get("options", []),
                }))
            elif "request" in step:
                request = step["request"]
                self.wait_for_response(self.ask(request.get("method"), request.get("params", {})))
            elif "mcp" in step:
                self.call_mcp(step["mcp"])
            elif step.get("waitCancel"):
                self.wait_cancel()
            elif "stop" in step:
                self.answer(rid, {"stopReason": step["stop"]})
                return
            elif "error" in step:
                self.send({"jsonrpc": "2.0", "id": rid, "error": step["error"]})
                return
            elif "exit" in step:
                sys.stderr.write("scripted agent exiting\n")
                sys.stderr.flush()
                sys.exit(step["exit"])
        self.answer(rid, {"stopReason": "end_turn"})

    def ask(self, method, params):
        self.agent_id += 1
        rid = self.agent_id
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return rid

    def wait_for_response(self, rid):
        # Other messages are taken as they come: a request from Search waits
        # until this one is done, a cancel is noted, a response for someone
        # else is ignored.
        while True:
            message = self.next_message()
            if "method" in message:
                if "id" in message:
                    self.deferred.append(message)
                else:
                    self.handle_notification(message)
                continue
            if message.get("id") == rid:
                return message

    def wait_cancel(self, limit=10):
        deadline = time.time() + limit
        while not self.cancelled:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            message = self.next_message(timeout=remaining)
            if message == "timeout":
                break
            if "method" in message:
                if "id" in message:
                    self.deferred.append(message)
                else:
                    self.handle_notification(message)

    def update(self, session, update):
        self.notify("session/update", {"sessionId": session, "update": update})

    # ----- MCP -----

    def remember_mcp(self, params):
        servers = params.get("mcpServers")
        if servers and self.mcp_server is None:
            self.mcp_server = servers[0]

    def call_mcp(self, step):
        if self.mcp is None:
            if not self.mcp_server:
                # No server was given (a one-shot): the step can't run, and
                # the script says so rather than starting nothing.
                self.log.line({"mcpResult": {"error": "No MCP server was given"}})
                return
            self.start_mcp()
        self.mcp_id += 1
        rid = self.mcp_id
        self.mcp_send({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                       "params": {"name": step.get("name"), "arguments": step.get("arguments", {})}})
        response = self.mcp_read(rid)
        self.log.line({"mcpResult": response.get("result", response.get("error"))})

    def start_mcp(self):
        entry = self.mcp_server or {}
        environment = dict(os.environ)
        for pair in entry.get("env") or []:
            environment[pair.get("name")] = pair.get("value")
        command = [entry.get("command", "")] + list(entry.get("args") or [])
        self.mcp = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, env=environment)
        self.mcp_id = 0
        self.mcp_send({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                       "params": {"protocolVersion": "2025-06-18",
                                  "clientCapabilities": {},
                                  "clientInfo": {"name": "scripted", "version": "1"}}})
        self.mcp_read(0)
        self.mcp_send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def mcp_send(self, message):
        self.mcp.stdin.write((json.dumps(message) + "\n").encode())
        self.mcp.stdin.flush()

    def mcp_read(self, rid):
        while True:
            line = self.mcp.stdout.readline()
            if not line:
                return {}
            try:
                message = json.loads(line.decode())
            except ValueError:
                continue
            if "method" not in message and message.get("id") == rid:
                return message

    # ----- letting go -----

    def cleanup(self):
        if self.mcp is None:
            return
        try:
            self.mcp.stdin.close()
        except OSError:
            pass
        try:
            self.mcp.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: scripted-acp-agent.py <scenario.json> <log.jsonl>\n")
        return 2
    try:
        with open(argv[1]) as handle:
            scenario = json.load(handle)
    except (OSError, ValueError):
        scenario = {}
    agent = Scripted(scenario, Log(argv[2]))
    threading.Thread(target=agent.reader, daemon=True).start()
    return agent.run()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
