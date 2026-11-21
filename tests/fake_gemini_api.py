#!/usr/bin/env python3
"""A local stand-in for the Gemini API (generateContent / streamGenerateContent) for offline smoke tests.
argv: port-file log-file plan-file. The plan is a JSON list; each model turn takes the next item: {"call": name, "args": {...}}
asks for a tool call, {"text": "..."} answers. Every request body is appended to the log as one JSON line."""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
portf, logf, planf = sys.argv[1:4]
plan = json.load(open(planf)); turn = [0]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj, sse=False):
        b = (("data: " + json.dumps(obj) + "\r\n\r\n") if sse else json.dumps(obj)).encode()
        self.send_response(code); self.send_header("Content-Type", "text/event-stream" if sse else "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        with open(logf, "a") as f: f.write(json.dumps({"method": "GET", "path": self.path}) + "\n")
        self._send(200, {"models": []})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n).decode("utf-8", "replace")
        try: req = json.loads(body)
        except Exception: req = {"raw": body[:2000]}
        with open(logf, "a") as f: f.write(json.dumps({"path": self.path, "key": bool(self.headers.get("x-goog-api-key")), "body": req}) + "\n")
        if ":countTokens" in self.path: return self._send(200, {"totalTokens": 10})
        if ":embedContent" in self.path: return self._send(200, {"embedding": {"values": [0.0]}})
        sse = "alt=sse" in self.path
        # a side request (routing, summaries, next-speaker checks) that asks for JSON gets a neutral answer
        gc = req.get("generationConfig", {}) if isinstance(req, dict) else {}
        if gc.get("responseMimeType") == "application/json" or gc.get("responseJsonSchema") or gc.get("responseSchema"):
            part = {"text": json.dumps({"next_speaker": "user", "reasoning": "done", "model_choice": "flash"})}
        else:
            i = min(turn[0], len(plan) - 1); turn[0] += 1; step = plan[i]
            part = {"functionCall": {"name": step["call"], "args": step.get("args", {})}} if "call" in step else {"text": step["text"]}
        self._send(200, {"candidates": [{"content": {"role": "model", "parts": [part]}, "finishReason": "STOP", "index": 0}],
                         "usageMetadata": {"promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2}}, sse)
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(portf, "w").write(str(s.server_address[1]))
s.serve_forever()
