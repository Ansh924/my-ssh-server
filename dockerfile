FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-server python3 net-tools && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir /var/run/sshd && \
    echo 'root:KoyebSSH123' | chpasswd && \
    useradd -m -s /bin/bash sshuser && \
    echo 'sshuser:Pass12345' | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config && \
    echo "ClientAliveInterval 10" >> /etc/ssh/sshd_config && \
    echo "ClientAliveCountMax 360" >> /etc/ssh/sshd_config && \
    echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config && \
    echo "Compression yes" >> /etc/ssh/sshd_config && \
    echo "MaxStartups 500:30:1000" >> /etc/ssh/sshd_config

RUN cat > /ws.py << 'PYEOF'
import socket
import threading
import select
import time
import signal

LISTEN_PORT = 8080
SSH_HOST = "127.0.0.1"
SSH_PORT = 22
BUFFER = 131072

RESPONSE_101 = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nKeep-Alive: timeout=86400\r\n\r\n"

def turbo_sock(s):
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4194304)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4194304)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 10)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 5)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 100)
    except:
        pass

def tunnel(c, s):
    socks = [c, s]
    last = time.time()
    while True:
        try:
            r, _, e = select.select(socks, [], socks, 10)
            if e:
                break
            if not r:
                if time.time() - last > 3600:
                    break
                continue
            last = time.time()
            for sk in r:
                try:
                    d = sk.recv(BUFFER)
                    if not d:
                        return
                    if sk is c:
                        s.sendall(d)
                    else:
                        c.sendall(d)
                except:
                    return
        except:
            break

def handle(c, addr):
    s = None
    try:
        c.settimeout(30)
        turbo_sock(c)
        d = b""
        while b"\r\n\r\n" not in d and len(d) < 16384:
            try:
                x = c.recv(8192)
                if not x:
                    return
                d += x
            except:
                return
        try:
            c.sendall(RESPONSE_101)
        except:
            return
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(10)
        turbo_sock(s)
        for i in range(3):
            try:
                s.connect((SSH_HOST, SSH_PORT))
                break
            except:
                if i == 2:
                    return
                time.sleep(0.3)
        c.settimeout(None)
        s.settimeout(None)
        tunnel(c, s)
    except:
        pass
    finally:
        try:
            c.close()
        except:
            pass
        try:
            if s:
                s.close()
        except:
            pass

def main():
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(1024)
    print(f"[+] Turbo SSH Proxy on :{LISTEN_PORT}", flush=True)
    while True:
        try:
            c, a = srv.accept()
            t = threading.Thread(target=handle, args=(c, a))
            t.daemon = True
            t.start()
        except:
            time.sleep(0.05)

if __name__ == "__main__":
    main()
PYEOF

RUN cat > /start.sh << 'SHEOF'
#!/bin/bash
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
sysctl -w net.core.wmem_max=16777216 2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_time=30 2>/dev/null || true

start_ssh() {
    while true; do
        echo "[SSH] Starting..."
        /usr/sbin/sshd -D -e
        echo "[SSH] Died, restart in 2s..."
        sleep 2
    done
}

start_ws() {
    while true; do
        echo "[WS] Starting..."
        python3 -u /ws.py
        echo "[WS] Died, restart in 2s..."
        sleep 2
    done
}

start_ssh &
sleep 3
start_ws
SHEOF

RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]
