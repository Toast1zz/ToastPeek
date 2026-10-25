#!/usr/bin/env python3
"""Loopback-only pages for repeatable WebKit integration tests; no external traffic."""
import http.server
import json
from pathlib import Path
import sys
import time
import urllib.parse

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith('/download/'):
            payload = (path.rsplit('/', 1)[-1] + '\n').encode() * (262144 if path.endswith('/slow') else 32768)
            start = 0
            if self.headers.get('Range', '').startswith('bytes='):
                start = int(self.headers['Range'][6:].split('-')[0])
            self.send_response(206 if start else 200)
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('ETag', '"toastpeek-fixture-v1"')
            self.send_header('Last-Modified', 'Fri, 23 Oct 2026 00:00:00 GMT')
            if start:
                self.send_header('Content-Range', f'bytes {start}-{len(payload)-1}/{len(payload)}')
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="same.txt"')
            self.send_header('Content-Length', str(len(payload)-start))
            self.end_headers()
            try:
                for offset in range(start, len(payload), 8192):
                    self.wfile.write(payload[offset:offset + 8192])
                    self.wfile.flush()
                    time.sleep(.02 if path.endswith('/slow') else .005)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path == '/auto-popup':
            body = '<h1>Automatic popup test</h1><script>window.result=window.open("/child")===null</script>'
        elif path == '/long':
            body = ''.join(f'<p style="height:100px">Printed paragraph {i}</p>' for i in range(35))
        elif path == '/child':
            body = '<h1>Child page</h1><script>if(opener)opener.postMessage("child-ready",location.origin)</script>'
        else:
            body = '''<h1 id="marker">Visible fixture page</h1>
            <input id="text" value="preserve this value"><input id="upload" type="file" multiple>
            <button id="popup" onclick="window.child=window.open('/child')">Open child</button>
            <script>window.received='';addEventListener('message',e=>window.received=e.data);</script>
            <a href="/download/a" download>Download A</a>'''
        page = ('<!doctype html><html><head><title>ToastPeek integration fixture</title>'
                '<meta charset="utf-8"><style>body{background:#d8effa;color:#152134;font:20px sans-serif;padding:30px}</style>'
                '</head><body>' + body + '</body></html>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(page)))
        self.end_headers()
        self.wfile.write(page)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Path(sys.argv[1]).write_text(json.dumps({'port': server.server_port}))
server.serve_forever()
