FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y openssh-server python3 net-tools && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# SSH setup with keep-alive
RUN mkdir /var/run/sshd && \
    echo 'root:KoyebSSH123' | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config && \
    echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config && \
    echo "ClientAliveCountMax 100" >> /etc/ssh/sshd_config && \
    echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config && \
    echo "MaxStartups 100:30:200" >> /etc/ssh/sshd_config

# Create SSH user
RUN useradd -m -s /bin/bash sshuser && \
    echo 'sshuser:Pass12345' | chpasswd

# WebSocket-to-SSH proxy
RUN cat > /ws.py << 'PYEOF'
import socket
import threading
import select
import sys

LISTEN_PORT = 8080
SSH_HOST = "127.0.0.1"
SSH_PORT = 22
BUFFER = 65536

RESPONSE_101 = (
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
