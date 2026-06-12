FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y openssh-server dropbear python3 net-tools && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# SSH setup
RUN mkdir /var/run/sshd && \
    echo 'root:KoyebSSH123' | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config && \
    echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config && \
    echo "ClientAliveCountMax 100" >> /etc/ssh/sshd_config && \
    echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config

# Create user
RUN useradd -m -s /bin/bash sshuser && \
    echo 'sshuser:Pass12345' | chpasswd

# Dropbear setup (lighter SSH)
RUN mkdir -p /etc/dropbear && \
    dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key && \
    dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key && \
    dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key

# WebSocket proxy with improved connection handling
RUN cat > /ws.py << 'PYEOF'
import socket
import threading
import select
import time
import sys

LISTEN_PORT = 8080
SSH_HOST = "127.0.0.1"
SSH_PORT = 22
DROPBEAR_PORT = 444
BUFFER = 65536

RESPONSE_101 = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n"
    b"Sec-WebSocket-Accept: koyeb\r\n"
    b"\r\n"
)

def tunnel(client_sock, ssh_sock):
    sockets = [client_sock, ssh_sock]
    timeout_count = 0
    
    while True:
        try:
            r, _, e = select.select(sockets, [], sockets, 3)
            
            if e:
                break
            
            if not r:
                timeout_count += 1
                if timeout_count > 60:  # 3 minutes idle
                    break
                continue
            
            timeout_count = 0
            
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
        client_sock.settimeout(15)
        
        # Read HTTP request
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 8192:
            try:
                chunk = client_sock.recv(BUFFER)
                if not chunk:
                    client_sock.close()
                    return
                data += chunk
            except:
                break
        
        # Send 101 response immediately
        client_sock.sendall(RESPONSE_101)
        
        # Connect to SSH backend
        ssh_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh_sock.settimeout(10)
        
        # Try OpenSSH first, fallback to Dropbear
        try:
            ssh_sock.connect((SSH_HOST, SSH_PORT))
        except:
            ssh_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            ssh_sock.connect((SSH_HOST, DROPBEAR_PORT))
        
        # Remove timeout for tunneling
        client_sock.settimeout(None)
        ssh_sock.settimeout(None)
        
        # Enable TCP keepalive on both
        for s in [client_sock, ssh_sock]:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        
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
    print(f"[+] WebSocket-SSH proxy listening on 0.0.0.0:{LISTEN_PORT}", flush=True)
    print(f"[+] Forwarding to SSH on 127.0.0.1:{SSH_PORT}", flush=True)
    
    while True:
        try:
            client, addr = srv.accept()
            t = threading.Thread(target=handle_client, args=(client, addr))
            t.daemon = True
            t.start()
        except Exception as e:
            print(f"[ACCEPT ERROR] {e}", flush=True)

if __name__ == "__main__":
    main()
PYEOF

# Startup script
RUN cat > /start.sh << 'SHEOF'
#!/bin/bash
echo "[*] Starting OpenSSH on port 22..."
service ssh start

echo "[*] Starting Dropbear on port 444..."
dropbear -p 444 -F &

sleep 2

echo "[*] Checking services..."
netstat -tlnp 2>/dev/null | grep -E "22|444"

echo "[*] Starting WebSocket proxy on port 8080..."
exec python3 -u /ws.py
SHEOF

RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]                data = client.recv(8192)\n\
                if not data: break\n\
                ssh.send(data)\n\
            if ssh in r:\n\
                data = ssh.recv(8192)\n\
                if not data: break\n\
                client.send(data)\n\
    except: pass\n\
    finally:\n\
        client.close()\n\
\n\
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)\n\
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n\
s.bind(("0.0.0.0", LISTEN_PORT))\n\
s.listen(50)\n\
print(f"WebSocket proxy on port {LISTEN_PORT}")\n\
while True:\n\
    c, _ = s.accept()\n\
    threading.Thread(target=handle, args=(c,)).start()\n\
' > /ws-proxy.py && chmod +x /ws-proxy.py

# Startup script
RUN echo '#!/bin/bash\n\
service ssh start\n\
python3 /ws-proxy.py &\n\
tail -f /dev/null\n\
' > /start.sh && chmod +x /start.sh

EXPOSE 22 8080

CMD ["/start.sh"]
