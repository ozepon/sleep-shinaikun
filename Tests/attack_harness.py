import http.server
import threading
import subprocess
import pathlib
import tempfile
import shutil
import json

root = pathlib.Path(__file__).resolve().parents[1]
hits = []
class AttackServer(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        hits.append(self.path)
        if self.path == '/redirect':
            self.send_response(307)
            self.send_header('Location', 'http://127.0.0.1:18766/steal')
        else:
            self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(('127.0.0.1', 18766), AttackServer)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    result = subprocess.run([str(root/'build/security-tests'), '--redirect-test'], capture_output=True, text=True, timeout=20)
    print(result.stdout, end='')
    assert result.returncode == 0, result.stderr
    assert hits == ['/redirect'], hits
    print('PASS: redirect destination received ZERO requests')
finally:
    server.shutdown()
    server.server_close()

app = root/'build/スリープしない君.app'
subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], check=True)
print('PASS: original application signature verifies')
with tempfile.TemporaryDirectory(prefix='sleep-tamper-') as temporary:
    copied = pathlib.Path(temporary)/'Tampered.app'
    shutil.copytree(str(app), str(copied))
    exe = copied/'Contents/MacOS/LidAwake'
    with exe.open('r+b') as f:
        f.seek(8192)
        value = f.read(1)
        f.seek(8192)
        f.write(bytes([value[0] ^ 1]))
    verdict = subprocess.run(['/usr/bin/codesign','--verify','--strict',str(copied)], capture_output=True)
    assert verdict.returncode != 0
    print('PASS: modified executable fails signature verification')

main = (root/'Sources/main.swift').read_text()
assert 'do shell script \\"/usr/bin/pmset -a disablesleep' in main
assert '(value ? 1 : 0)' in main
assert 'topic' not in main[:main.index('struct Panel')]
print('PASS: privileged command uses fixed absolute path and boolean only (source inspection)')
print('Local attack harness completed. No external service was contacted.')
