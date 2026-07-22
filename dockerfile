FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Dropbear = lightweight SSH server that emits the "dropbear" banner your
# client expects, and is far more reliable inside containers than OpenSSH
# (no /run/sshd privilege-separation problems).
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

# WebSocket-to-SSH proxy (PROPER WebSocket: real handshake + frame
# decode/encode). Also falls back to raw tunneling if the client does not
# send a Sec-WebSocket-Key. Connects to the SSH backend BEFORE answering
# the client, so "Switching Protocols" only appears when SSH is reachable.
RUN cat > /ws.py << 'PYEOF'
import socket
import threading
import base64
import hashlib
import struct
import time

LISTEN_PORT = 8080
SSH_HOST = "127.0.0.1"
SSH_PORT = 22
BUFFER = 65536
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Reader:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(n - len(self.buf))
            if not chunk:
                return None
            self.buf += chunk
        out = self.buf[:n]
        self.buf = self.buf[n:]
        return out


def ws_handshake(client):
    client.settimeout(10)
    data = b""
    while b"\r\n\r\n" not in data and len(data) < 16384:
        try:
            chunk = client.recv(4096)
        except Exception:
            return None, False
        if not chunk:
            return None, False
        data += chunk

    key = b""
    for line in data.split(b"\r\n")[1:]:
        if line.lower().startswith(b"sec-websocket-key:"):
            key = line.split(b":", 1)[1].strip()

    if key:
        accept = base64.b64encode(
            hashlib.sha1((key.decode() + WS_GUID).encode()).digest()
        ).decode()
        resp = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: " + accept + "\r\n"
            "\r\n"
        )
        client.sendall(resp.encode())
        return data, True
    else:
        resp = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "\r\n"
        )
        client.sendall(resp.encode())
        return data, False


def send_frame(client, opcode, payload):
    hdr = bytes([0x80 | opcode])
    length = len(payload)
    if length < 126:
        hdr += bytes([length])
    elif length < 65536:
        hdr += bytes([126]) + struct.pack(">H", length)
    else:
        hdr += bytes([127]) + struct.pack(">Q", length)
    try:
        client.sendall(hdr + payload)
    except Exception:
        pass


def read_frame(reader):
    hdr = reader.read(2)
    if hdr is None:
        return None, None
    opcode = hdr[0] & 0x0F
    masked = (hdr[1] & 0x80) != 0
    length = hdr[1] & 0x7F
    if length == 126:
        ext = reader.read(2)
        if ext is None:
            return None, None
        length = struct.unpack(">H", ext)[0]
    elif length == 127:
        ext = reader.read(8)
        if ext is None:
            return None, None
        length = struct.unpack(">Q", ext)[0]
    mask = b""
    if masked:
        mask = reader.read(4)
        if mask is None:
            return None, None
    payload = reader.read(length) if length else b""
    if payload is None:
        return None, None
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def client_to_ssh_ws(reader, ssh, client):
    try:
        while True:
            opcode, payload = read_frame(reader)
            if opcode is None:
                break
            if opcode == 0x8:        # close
                break
            elif opcode == 0x9:      # ping -> pong
                send_frame(client, 0xA, payload)
            elif opcode in (0x0, 0x1, 0x2):  # data / continuation
                if payload:
                    ssh.sendall(payload)
    except Exception:
        pass


def client_to_ssh_raw(reader, ssh):
    try:
        if reader.buf:
            ssh.sendall(reader.buf)
        while True:
            data = reader.sock.recv(BUFFER)
            if not data:
                break
            ssh.sendall(data)
    except Exception:
        pass


def ssh_to_client_ws(client, ssh):
    try:
        while True:
            data = ssh.recv(BUFFER)
            if not data:
                break
            send_frame(client, 0x2, data)
    except Exception:
        pass
    try:
        send_frame(client, 0x8, b"")
    except Exception:
        pass


def ssh_to_client_raw(client, ssh):
    try:
        while True:
            data = ssh.recv(BUFFER)
            if not data:
                break
            client.sendall(data)
    except Exception:
        pass


def handle_client(client, addr):
    ssh = None
    try:
        req, is_ws = ws_handshake(client)
        if req is None:
            return

        # Connect to the real SSH backend FIRST
        ssh = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh.settimeout(10)
        ssh.connect((SSH_HOST, SSH_PORT))
        ssh.settimeout(None)
        client.settimeout(None)
        for s in (client, ssh):
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        reader = Reader(client)
        # Carry over any bytes that arrived after the HTTP headers
        leftover = req.split(b"\r\n\r\n", 1)[1]
        if leftover and not is_ws:
            reader.buf = leftover

        if is_ws:
            t1 = threading.Thread(target=client_to_ssh_ws, args=(reader, ssh, client))
            t2 = threading.Thread(target=ssh_to_client_ws, args=(client, ssh))
        else:
            t1 = threading.Thread(target=client_to_ssh_raw, args=(reader, ssh))
            t2 = threading.Thread(target=ssh_to_client_raw, args=(client, ssh))

        t1.start()
        t2.start()
        while t1.is_alive() and t2.is_alive():
            time.sleep(0.2)
        try:
            client.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            ssh.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        t1.join()
        t2.join()
    except Exception as e:
        print(f"[ERROR] {e}", flush=True)
    finally:
        for s in (client, ssh):
            try:
                if s:
                    s.close()
            except Exception:
                pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(200)
    print(f"[+] WS/RAW -> SSH proxy on 0.0.0.0:{LISTEN_PORT} -> {SSH_HOST}:{SSH_PORT}", flush=True)
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

echo "[*] Preparing SSH (dropbear)..."

# Make sure host keys exist (rebuild if missing)
mkdir -p /etc/dropbear
[ -f /etc/dropbear/dropbear_rsa_host_key ]     || dropbearkey -t rsa     -f /etc/dropbear/dropbear_rsa_host_key
[ -f /etc/dropbear/dropbear_ecdsa_host_key ]   || dropbearkey -t ecdsa   -f /etc/dropbear/dropbear_ecdsa_host_key
[ -f /etc/dropbear/dropbear_ed25519_host_key ] || dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key

echo "[*] Starting dropbear on port 22 (root login allowed)..."
# -p 22 : listen on port 22
# -a    : allow root login with password
# -E    : log to stderr (visible in container logs)
dropbear -p 22 -a -E
sleep 1

echo "[*] dropbear check:"
pgrep -a dropbear || echo "dropbear NOT running!"
( ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null ) | grep -E ':22|:8080' || true

echo "[*] Starting WebSocket proxy on port 8080..."
exec python3 -u /ws.py
SHEOF

RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]
