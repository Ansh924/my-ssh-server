FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install minimal but powerful packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-server \
        python3 \
        python3-pip \
        net-tools \
        iproute2 \
        procps \
        stunnel4 \
        haproxy && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ===== HIGH-PERFORMANCE SSH CONFIG =====
RUN mkdir /var/run/sshd && \
    echo 'root:KoyebSSH123' | chpasswd && \
    useradd -m -s /bin/bash sshuser && \
    echo 'sshuser:Pass12345' | chpasswd && \
    cat > /etc/ssh/sshd_config << 'EOF'
Port 22
Protocol 2
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM no
X11Forwarding no
PrintMotd no
UseDNS no
GSSAPIAuthentication no

# ===== SPEED BOOSTERS =====
# Fastest ciphers (less CPU, more speed)
Ciphers aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr
MACs hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org

# Enable compression for text/web
Compression yes

# ===== ULTRA KEEP-ALIVE =====
ClientAliveInterval 10
ClientAliveCountMax 360
TCPKeepAlive yes

# Allow heavy tunneling
GatewayPorts yes
AllowTcpForwarding yes
PermitTunnel yes
AllowAgentForwarding yes

# High connection limits
MaxStartups 1000:30:2000
MaxSessions 500
LoginGraceTime 300

# Disable slow features
PrintLastLog no
Banner none
EOF

# ===== ULTRA-FAST WEBSOCKET PROXY =====
RUN cat > /ws.py << 'PYEOF'
import socket
import threading
import select
import time
import sys
import os
import gc
import signal

LISTEN_PORT = 8080
SSH_HOST = "127.0.0.1"
SSH_PORT = 22

# LARGE BUFFER for max throughput
BUFFER = 131072  # 128KB chunks

ACTIVE_CONNS = 0
TOTAL_CONNS = 0
LOCK = threading.Lock()

RESPONSE_101 = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Server: nginx/1.24.0\r\n"
    b"Date: Mon, 01 Jan 2024 00:00:00 GMT\r\n"
    b"Connection: Upgrade\r\n"
    b"Upgrade: websocket\r\n"
    b"Sec-WebSocket-Accept: koyeb-turbo\r\n"
    b"Keep-Alive: timeout=86400, max=10000\r\n"
    b"X-Accel-Buffering: no\r\n"
    b"\r\n"
)

def turbo_socket(sock):
    """Apply ALL speed optimizations to socket"""
    try:
        # Basic options
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        
        # MASSIVE buffers (4MB each)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4194304)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4194304)
        
        # Aggressive keepalive
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 10)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 5)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 100)
        
        # Quick ACK (lower latency)
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_QUICKACK, 1)
        except:
            pass
        
        # No linger (close fast)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, 
                       struct.pack('ii', 0, 0))
    except:
        pass

import struct

def tunnel_turbo(client_sock, ssh_sock):
    """High-speed bidirectional tunnel"""
    sockets = [client_sock, ssh_sock]
    last_activity = time.time()
    
    # Use larger select timeout for less CPU
    while True:
        try:
            r, _, e = select.select(sockets, [], sockets, 10)
            
            if e:
                break
            
            if not r:
                # Long idle = check if still alive
                if time.time() - last_activity > 3600:  # 1 hour idle max
                    break
                continue
            
            last_activity = time.time()
            
            for sock in r:
                try:
                    # Receive max chunk
                    data = sock.recv(BUFFER)
                    if not data:
                        return
                    
                    # Send to opposite socket (sendall ensures complete send)
                    if sock is client_sock:
                        ssh_sock.sendall(data)
                    else:
                        client_sock.sendall(data)
                        
                except (socket.error, BlockingIOError, OSError):
                    return
        except (select.error, OSError, ValueError):
            break
        except Exception:
            break

def handle_client(client_sock, addr):
    global ACTIVE_CONNS, TOTAL_CONNS
    ssh_sock = None
    
    with LOCK:
        ACTIVE_CONNS += 1
        TOTAL_CONNS += 1
    
    try:
        client_sock.settimeout(30)
        turbo_socket(client_sock)
        
        # Fast HTTP header read
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 16384:
            try:
                chunk = client_sock.recv(8192)
                if not chunk:
                    return
                data += chunk
            except socket.timeout:
                break
            except:
                return
        
        # Send 101 immediately
        try:
            client_sock.sendall(RESPONSE_101)
        except:
            return
        
        # Connect to SSH with retry
        ssh_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh_sock.settimeout(10)
        turbo_socket(ssh_sock)
        
        for attempt in range(3):
            try:
                ssh_sock.connect((SSH_HOST, SSH_PORT))
                break
            except:
                if attempt == 2:
                    return
                time.sleep(0.3)
        
        # Blocking mode for tunnel
        client_sock.settimeout(None)
        ssh_sock.settimeout(None)
        
        # GO TURBO!
        tunnel_turbo(client_sock, ssh_sock)
        
    except Exception:
        pass
    finally:
        with LOCK:
            ACTIVE_CONNS -= 1
        try:
            client_sock.shutdown(socket.SHUT_RDWR)
        except:
            pass
        try:
            client_sock.close()
        except:
            pass
        try:
            if ssh_sock:
                ssh_sock.shutdown(socket.SHUT_RDWR)
                ssh_sock.close()
        except:
            pass

def cleanup_loop():
    """Memory cleanup every 2 mins"""
    while True:
        time.sleep(120)
        gc.collect()

def stats_loop():
    """Print stats every 5 mins"""
    while True:
        time.sleep(300)
        print(f"[STATS] Active: {ACTIVE_CONNS} | Total: {TOTAL_CONNS}", flush=True)

def main():
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    
    threading.Thread(target=cleanup_loop, daemon=True).start()
    threading.Thread(target=stats_loop, daemon=True).start()
    
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    
    # Try TCP Fast Open (Linux 3.7+)
    try:
        srv.setsockopt(socket.IPPROTO_TCP, 23, 5)  # TCP_FASTOPEN
    except:
        pass
    
    # Large listen backlog
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(1024)
    
    print(f"[+] 🚀 TURBO WebSocket-SSH Proxy", flush=True)
    print(f"[+] 📡 Listening: 0.0.0.0:{LISTEN_PORT}", flush=True)
    print(f"[+] 🎯 SSH Backend: {SSH_HOST}:{SSH_PORT}", flush=True)
    print(f"[+] ⚡ Buffer Size: {BUFFER} bytes", flush=True)
    print(f"[+] 💪 Max Backlog: 1024", flush=True)
    
    while True:
        try:
            client, addr = srv.accept()
            t = threading.Thread(target=handle_client, args=(client, addr))
            t.daemon = True
            t.start()
        except Exception as e:
            print(f"[ACCEPT ERROR] {e}", flush=True)
            time.sleep(0.05)

if __name__ == "__main__":
    main()
PYEOF

# ===== TURBO STARTUP SCRIPT =====
RUN cat > /start.sh << 'SHEOF'
#!/bin/bash
set +e

echo "🚀 ===== KOYEB TURBO SSH SERVER ====="

# ===== KERNEL TUNING FOR MAX SPEED =====
echo "[*] Applying speed boosters..."

# BBR congestion control (Google's algorithm - HUGE speed boost!)
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
sysctl -w net.core.default_qdisc=fq 2>/dev/null || true

# Massive buffer sizes
sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
sysctl -w net.core.wmem_max=16777216 2>/dev/null || true
sysctl -w net.core.rmem_default=4194304 2>/dev/null || true
sysctl -w net.core.wmem_default=4194304 2>/dev/null || true
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" 2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" 2>/dev/null || true

# TCP optimizations
sysctl -w net.ipv4.tcp_window_scaling=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_timestamps=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_sack=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true
sysctl -w net.ipv4.tcp_low_latency=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_no_metrics_save=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null || true

# Aggressive keepalive
sysctl -w net.ipv4.tcp_keepalive_time=30 2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_intvl=10 2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_probes=10 2>/dev/null || true

# Connection handling
sysctl -w net.core.somaxconn=4096 2>/dev/null || true
sysctl -w net.ipv4.tcp_max_syn_backlog=8192 2>/dev/null || true
sysctl -w net.core.netdev_max_backlog=16384 2>/dev/null || true
sysctl -w net.ipv4.tcp_max_tw_buckets=2000000 2>/dev/null || true
sysctl -w net.ipv4.tcp_tw_reuse=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_fin_timeout=15 2>/dev/null || true

# File descriptor limits
ulimit -n 1048576 2>/dev/null || true
ulimit -u 65535 2>/dev/null || true

echo "[*] ✅ Network optimizations applied!"

# Verify BBR is active
echo "[*] Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'cubic')"

# Auto-restart SSH
start_ssh() {
    while true; do
        echo "[SSH] Starting daemon..."
        /usr/sbin/sshd -D -e -o "MaxStartups=1000:30:2000"
        echo "[SSH] ⚠️  Died, restart in 2s..."
        sleep 2
    done
}

# Auto-restart WebSocket
start_ws() {
    while true; do
        echo "[WS] Starting proxy..."
        python3 -u /ws.py
        echo "[WS] ⚠️  Died, restart in 2s..."
        sleep 2
    done
}

# Health monitor
health_check() {
    while true; do
        sleep 60
        ts=$(date '+%H:%M:%S')
        ssh_ok=$(netstat -tlnp 2>/dev/null | grep -c ":22 ")
        ws_ok=$(netstat -tlnp 2>/dev/null | grep -c ":8080 ")
        mem=$(free -m | awk '/^Mem:/{print $3"MB/"$2"MB"}')
        echo "[💓 $ts] SSH:$ssh_ok WS:$ws_ok MEM:$mem"
    done
}

# Start everything
start_ssh &
sleep 3
health_check &
start_ws
SHEOF

RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]RESPONSE_101 = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n"
    b"\r\n"
)

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
                except:
                    return
        except:
            break

def handle_client(client_sock, addr):
    ssh_sock = None
    try:
        client_sock.settimeout(20)
        
        # Read HTTP request fully
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
            except:
                client_sock.close()
                return
        
        # Send 101 Switching Protocols
        try:
            client_sock.sendall(RESPONSE_101)
        except:
            client_sock.close()
            return
        
        # Connect to SSH backend
        ssh_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh_sock.settimeout(10)
        ssh_sock.connect((SSH_HOST, SSH_PORT))
        
        # Remove timeouts for tunneling
        client_sock.settimeout(None)
        ssh_sock.settimeout(None)
        
        # Enable keepalive
        for s in [client_sock, ssh_sock]:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        
        # Start tunneling
        tunnel(client_sock, ssh_sock)
        
    except Exception as e:
        print(f"[ERROR] {e}", flush=True)
    finally:
        try:
            client_sock.close()
        except:
            pass
        try:
            if ssh_sock:
                ssh_sock.close()
        except:
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
echo "[*] Starting OpenSSH on port 22..."
service ssh start
sleep 2
echo "[*] SSH status:"
service ssh status || true
netstat -tlnp 2>/dev/null | grep :22 || true
echo "[*] Starting WebSocket proxy on port 8080..."
exec python3 -u /ws.py
SHEOF

RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]
