#!/usr/bin/env python3
"""Loopback-only pages for repeatable WebKit integration tests; no external traffic."""
import http.server
import struct
import zlib
import json
from pathlib import Path
import sys
import time
import urllib.parse

def png(red, green, blue):
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', 1, 1, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes([0, red, green, blue]))) + chunk(b'IEND', b''))

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        with Path(sys.argv[1]).with_name('requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': self.path, 'cookie': self.headers.get('Cookie', '')}) + '\n')
        if path == '/icon/redirect':
            self.send_response(302)
            self.send_header('Location', f'http://localhost:{self.server.server_port}/icon/redirect-target')
            self.end_headers()
            return
        if path == '/icon/stalled':
            payload = png(0, 0, 255)
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.flush()
            time.sleep(8)
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path.startswith('/icon/') or path == '/favicon.ico':
            payload = (b'x' * 524289 if path == '/icon/oversized' else b'x' * 524288 if path == '/icon/exact-size' else b'not an image' if path == '/icon/invalid'
                       else png(255, 0, 0) if 'identity=alpha' in self.headers.get('Cookie', '') else png(0, 0, 255))
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Cache-Control', 'no-store')
            # The oversized fixture omits a length to exercise the stream limit.
            if path != '/icon/oversized':
                self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
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
        if path == '/favicon-page':
            body = '<link rel="icon" href="/icon/invalid"><h1>Fallback icon fixture</h1>'
        elif path == '/auto-popup':
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
        if path == '/icon-csp-page':
            self.send_header('Content-Security-Policy', "default-src 'none'; connect-src 'none'")
        self.send_header('Content-Length', str(len(page)))
        self.end_headers()
        self.wfile.write(page)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Path(sys.argv[1]).write_text(json.dumps({'port': server.server_port}))
server.serve_forever()
