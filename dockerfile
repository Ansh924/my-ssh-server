FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Dropbear is a lightweight SSH server that is far more reliable inside
# containers than OpenSSH (no /run/sshd privilege-separation problems).
# It also sends the "dropbear" identification banner your client expects.
RUN apt-get update && \
    apt-get install -y dropbear python3 net-tools && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create users
RUN echo 'root:KoyebSSH123' | chpasswd && \
    useradd -m -s /bin/bash sshuser && \
    echo 'sshuser:Pass12345' | chpasswd

# Pre-generate Dropbear host keys at build time
RUN mkdir -p /etc/dropbear && \
    dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null || true && \
    dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key 2>/dev/null || true && \
    dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true

# WebSocket-to-SSH proxy
# Key fix: connect to the SSH backend FIRST, only send "101 Switching
# Protocols" AFTER the backend is reachable. This guarantees the client
# only sees "changing protocols" when a real SSH server is up, and the
# SSH banner ("dropbear" message) is forwarded immediately.
RUN cat > /ws.py << 'PYEOF'
import socket
import threading
import select
import base64
import hashlib

LISTEN_PORT = 8080
SSH_HOST = "127.0.0.1"
SSH_PORT = 22
BUFFER = 65536
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_accept(key):
    return base64.b64encode(
        hashlib.sha1((key + WS_GUID).encode()).digest()
    ).decode()


def tunnel(client_sock, ssh_sock):
    sockets = [client_sock, ssh_sock]
    while True:
        try:
            r, _, e = select.select(sockets, [], sockets, 120)
            if e or not r:
                break
            for sock in r:
                try:
                    data = sock.recv(BUFFER)
                    if not data:
                        return
                    if sock is client_sock:
                        ssh_sock.sendall(data)
                    else:
                        client_sock.sendall(data)
                except Exception:
                    return
        except Exception:
            break


def handle_client(client_sock, addr):
    ssh_sock = None
    try:
        client_sock.settimeout(20)

        # Read the full HTTP upgrade request
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 16384:
            try:
                chunk = client_sock.recv(BUFFER)
                if not chunk:
                    client_sock.close()
                    return
                data += chunk
            except socket.timeout:
                break
            except Exception:
                client_sock.close()
                return

        # Build the 101 response (RFC-compliant Sec-WebSocket-Accept if key present)
        key = ""
        for line in data.split(b"\r\n"):
            if line.lower().startswith(b"sec-websocket-key:"):
                key = line.split(b":", 1)[1].strip().decode()

        if key:
            accept = ws_accept(key)
            resp = (
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\n"
                b"Connection: Upgrade\r\n"
                b"Sec-WebSocket-Accept: " + accept.encode() + b"\r\n"
                b"\r\n"
            )
        else:
            resp = (
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\n"
                b"Connection: Upgrade\r\n"
                b"\r\n"
            )

        # Connect to the SSH backend FIRST (127.0.0.1:22)
        ssh_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh_sock.settimeout(10)
        ssh_sock.connect((SSH_HOST, SSH_PORT))
        ssh_sock.settimeout(None)

        # Forward any bytes that arrived after the HTTP headers
        leftover = data.split(b"\r\n\r\n", 1)[1]
        if leftover:
            ssh_sock.sendall(leftover)

        # Now that SSH is reachable, tell the client to switch protocols
        client_sock.sendall(resp)
        client_sock.settimeout(None)

        # Keepalive + low latency
        for s in (client_sock, ssh_sock):
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        tunnel(client_sock, ssh_sock)

    except Exception as e:
        print(f"[ERROR] {e}", flush=True)
        try:
            client_sock.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        except Exception:
            pass
    finally:
        try:
            client_sock.close()
        except Exception:
            pass
        try:
            if ssh_sock:
                ssh_sock.close()
        except Exception:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(200)
    print(f"[+] WebSocket-SSH proxy on 0.0.0.0:{LISTEN_PORT}", flush=True)
    print(f"[+] Forwarding to SSH 127.0.0.1:{SSH_PORT}", flush=True)
    while True:
        try:
            client, addr = srv.accept()
            t = threading.Thread(target=handle_client, args=(client, addr))
            t.daemon = True
            t.start()
        except Exception as e:
            print(f"[ACCEPT] {e}", flush=True)


if __name__ == "__main__":
    main()
PYEOF

# Startup script
RUN cat > /start.sh << 'SHEOF'
#!/bin/bash
set -e

echo "[*] Preparing SSH (dropbear)..."

# Make sure host keys exist (rebuild if missing)
mkdir -p /etc/dropbear
[ -f /etc/dropbear/dropbear_rsa_host_key ]    || dropbearkey -t rsa    -f /etc/dropbear/dropbear_rsa_host_key
[ -f /etc/dropbear/dropbear_ecdsa_host_key ]  || dropbearkey -t ecdsa  -f /etc/dropbear/dropbear_ecdsa_host_key
[ -f /etc/dropbear/dropbear_ed25519_host_key ]|| dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key

echo "[*] Starting dropbear on port 22 (root login allowed)..."
# -p 22    : listen on port 22
# -a       : allow root login with password
# -E       : log to stderr (visible in container logs)
dropbear -p 22 -a -E

sleep 1
echo "[*] dropbear processes:"
ps aux | grep -v grep | grep dropbear || true

echo "[*] Listening sockets:"
netstat -tlnp 2>/dev/null | grep -E ':22|:8080' || true

echo "[*] Starting WebSocket proxy on port 8080..."
exec python3 -u /ws.py
SHEOF

RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]
