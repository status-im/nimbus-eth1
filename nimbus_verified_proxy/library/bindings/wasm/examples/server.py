#!/usr/bin/env python3
"""
Static file server + transparent CORS proxy.
  GET/POST /proxy?url=<encoded-url>  — proxies to target, adds CORS headers
  Everything else                    — served from this directory
"""

import os
import urllib.request
import urllib.parse
from http.server import HTTPServer, SimpleHTTPRequestHandler

PORT = 8080

class Handler(SimpleHTTPRequestHandler):
    def guess_type(self, path):
        if path.endswith('.wasm'):
            return 'application/wasm'
        if path.endswith('.wasm.map') or path.endswith('.map'):
            return 'application/json'
        return super().guess_type(path)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path.startswith('/proxy?'):
            self._proxy('GET')
        else:
            super().do_GET()

    def do_POST(self):
        if self.path.startswith('/proxy?'):
            self._proxy('POST')
        else:
            super().do_POST()

    def _cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Accept')

    def _proxy(self, method):
        qs = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(qs)
        target = params.get('url', [''])[0]

        if not target:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'missing url param')
            return

        try:
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length) if length else None
            headers = {
                'User-Agent': 'Mozilla/5.0 (compatible; verifproxy-dev/1.0)',
            }
            for h in ('Content-Type', 'Accept'):
                v = self.headers.get(h)
                if v:
                    headers[h] = v

            req = urllib.request.Request(target, data=body, headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read()
                self.send_response(resp.status)
                self._cors()
                ct = resp.headers.get('Content-Type', 'application/json')
                self.send_header('Content-Type', ct)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        except Exception as e:
            self.send_response(502)
            self._cors()
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(str(e).encode())

    def log_message(self, fmt, *args):
        print(fmt % args)

os.chdir(os.path.dirname(os.path.abspath(__file__)))
print(f'Serving on http://localhost:{PORT}')
HTTPServer(('', PORT), Handler).serve_forever()
