#!/usr/bin/env python3
# ProxyCommand helper: CONNECT through the runtime tunnel proxy (port 3130)
# to a tailnet address, then relay stdin/stdout. Proxy URL (with its token)
# is read from the HTTPS_PROXY env var at runtime; nothing is hardcoded.
import os, socket, sys, threading, urllib.parse, base64

def main():
    host, port = sys.argv[1], int(sys.argv[2])
    proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    if not proxy:
        sys.exit("no proxy env")
    u = urllib.parse.urlparse(proxy)
    phost, pport = u.hostname, 3130
    s = socket.create_connection((phost, pport), timeout=120)
    auth = ""
    if u.username:
        cred = base64.b64encode(f"{urllib.parse.unquote(u.username)}:{urllib.parse.unquote(u.password or '')}".encode()).decode()
        auth = f"Proxy-Authorization: Basic {cred}\r\n"
    s.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n{auth}\r\n".encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            sys.exit("proxy closed during CONNECT")
        buf += chunk
    status = buf.split(b"\r\n", 1)[0]
    if b" 200 " not in status:
        sys.exit(f"CONNECT failed: {status!r}")
    rest = buf.split(b"\r\n\r\n", 1)[1]
    if rest:
        sys.stdout.buffer.write(rest); sys.stdout.buffer.flush()
    def pump_in():
        try:
            while True:
                data = sys.stdin.buffer.read1(65536) if hasattr(sys.stdin.buffer, "read1") else sys.stdin.buffer.read(65536)
                if not data:
                    # Do NOT shutdown(SHUT_WR) here: under systemd the ssh
                    # process's stdin is /dev/null, so EOF is immediate and
                    # spurious — shutting down would half-kill a healthy
                    # session (server->client only). ssh owns this helper's
                    # lifecycle and kills it when the session ends.
                    return
                s.sendall(data)
        except OSError:
            return
    t = threading.Thread(target=pump_in, daemon=True); t.start()
    try:
        while True:
            data = s.recv(65536)
            if not data:
                return
            sys.stdout.buffer.write(data); sys.stdout.buffer.flush()
    except OSError:
        return

if __name__ == "__main__":
    main()
