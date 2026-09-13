#!/usr/bin/env python3.11
"""Minimal deployed app. Stdlib only -- no node, no deps, ~500MB jail total.

The apps are fixtures (spec.org, Purpose); the product is the pipeline. This
serves the same JSON contract as apps/*/src/server.js so gates/e2e.sh asserts
identically against a jail and against a dev worktree.

Binds to jail loopback: only nginx is reachable from outside the jail, so
route ownership is a network fact rather than a convention.
"""
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP = os.environ["APP"]
PORT = int(os.environ["PORT"])
SHA = os.environ.get("BUILD_SHA", "dev")
ENV = os.environ.get("DEPLOY_ENV", "?")
ROUTES = json.loads(os.environ.get("ROUTES", "[]"))


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _head(self, body):
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("x-build-sha", SHA)
        self.send_header("x-app", APP)
        self.end_headers()

    def do_GET(self):
        body = json.dumps({"app": APP, "path": self.path, "block": ENV,
                           "sha": SHA, "routes": ROUTES}, indent=2).encode()
        self._head(body)
        self.wfile.write(body)

    # gates/e2e.sh probes the build sha with curl -I. Without this, HEAD
    # returns 501 and the "one estate" check sees zero builds -- which the
    # gate correctly reported as incoherent rather than passing.
    def do_HEAD(self):
        self._head(json.dumps({"app": APP, "sha": SHA}).encode())

    def log_message(self, *a):
        pass


class Server(ThreadingHTTPServer):
    allow_reuse_address = True      # a redeploy must not race TIME_WAIT


Server(("127.0.0.1", PORT), H).serve_forever()
