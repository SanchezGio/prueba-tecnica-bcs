#!/usr/bin/env bash
# Endurecimiento inspirado en CIS Benchmark para Ubuntu 22.04 (subconjunto
# pragmático, no una certificación completa — ver README "Limitaciones
# conocidas"). Aplica solo controles compatibles con el ciclo de vida efímero
# de la VM (no tiene sentido, por ejemplo, forzar rotación de contraseñas
# locales en una máquina que vive minutos).
set -euxo pipefail

# 1. Sin login por password en ningún caso — solo claves gestionadas por Azure
#    (y en la práctica, sin sesión interactiva: logonType = "Service" en el
#    Managed DevOps Pool, ver infra/devops-pool.tf).
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# 2. Deshabilitar servicios/protocolos no usados por un agente de build.
systemctl disable --now avahi-daemon.service 2>/dev/null || true
systemctl disable --now cups.service 2>/dev/null || true

# 3. auditd mínimo: registrar cambios a binarios sensibles y ejecución de
#    docker (trazabilidad si algo se ejecuta en la ventana de vida del agente).
cat >> /etc/audit/rules.d/agent-hardening.rules <<'EOF'
-w /usr/bin/docker -p x -k docker_exec
-w /etc/passwd -p wa -k identity_files
-w /etc/shadow -p wa -k identity_files
EOF

# 4. Kernel hardening básico (sysctl).
cat >> /etc/sysctl.d/99-agent-hardening.conf <<'EOF'
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
kernel.dmesg_restrict=1
EOF
sysctl --system

# 5. Sin cuentas de usuario adicionales ni claves SSH de terceros preinstaladas.
find /home -maxdepth 2 -name "authorized_keys" -delete 2>/dev/null || true

echo "Hardening de la imagen del agente completado."
