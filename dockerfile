FROM ubuntu:22.04

# Install SSH and required packages
RUN apt-get update && \
    apt-get install -y openssh-server dropbear stunnel4 nginx wget curl python3 && \
    apt-get clean

# Setup SSH
RUN mkdir /var/run/sshd
RUN echo 'root:KoyebSSH123' | chpasswd
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
RUN sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config

# Create custom user
RUN useradd -m -s /bin/bash sshuser && \
    echo 'sshuser:Pass12345' | chpasswd

# Setup WebSocket proxy (for bug host support)
RUN echo '#!/usr/bin/env python3\n\
import socket, threading, select, sys\n\
\n\
LISTEN_PORT = 8080\n\
SSH_HOST = "127.0.0.1"\n\
SSH_PORT = 22\n\
RESPONSE = "HTTP/1.1 101 Switching Protocols\\r\\n\\r\\n"\n\
\n\
def handle(client):\n\
    try:\n\
        client.recv(8192)\n\
        client.send(RESPONSE.encode())\n\
        ssh = socket.socket(socket.AF_INET, socket.SOCK_STREAM)\n\
        ssh.connect((SSH_HOST, SSH_PORT))\n\
        while True:\n\
            r, _, _ = select.select([client, ssh], [], [])\n\
            if client in r:\n\
                data = client.recv(8192)\n\
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
