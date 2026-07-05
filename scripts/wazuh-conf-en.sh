#!/bin/sh
##########################################################################################################
###### Script post-install for wazuh, executed by the wazuh-agents and wazuh-manager         #############
##########################################################################################################

#──── Exit on error, e=exit on error, u=exit on undefined var ──────────
set -eu

# Cambiar permisos del archivo authd.pass montado
if [ -f /var/ossec/etc/authd.pass ]; then
    chown root:wazuh /var/ossec/etc/authd.pass
    chmod 640 /var/ossec/etc/authd.pass
    echo "🔐 Permisos de authd.pass ajustados."
fi

# Instalar dependencias del docker-listener solo si falta (evita reinstalar en cada restart)
if ! python3 -c "import docker" >/dev/null 2>&1; then
    echo "📦 Instalando dependencias Python para docker-listener..."
    dnf install -y python3-pip
    pip3 install docker==7.1.0 urllib3==1.26.20 requests==2.32.2
    echo "✅ Dependencias docker-listener instaladas."
else
    echo "✅ Dependencias docker-listener ya presentes, se omite instalación."
fi

# Ejecutar el entrypoint original de la imagen del agente
exec /init "$@"