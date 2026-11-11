#!/bin/sh
# ---------------------------------------------------------------------------
# Preparar la configuración posterior a la instalación del agente Wazuh
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Detener la ejecución ante errores o variables sin definir
# ---------------------------------------------------------------------------
set -eu

# ---------------------------------------------------------------------------
# Ajustar los permisos del archivo de autenticación si está montado
# ---------------------------------------------------------------------------
if [ -f /var/ossec/etc/authd.pass ]; then
    chown root:wazuh /var/ossec/etc/authd.pass
    chmod 640 /var/ossec/etc/authd.pass
    echo "🔐 authd.pass permissions updated."
fi

# ---------------------------------------------------------------------------
# Instalar las dependencias del docker-listener solo cuando sean necesarias
# ---------------------------------------------------------------------------
#if ! python3 -c "import docker" >/dev/null 2>&1; then
#    echo "📦 Instalando dependencias Python para docker-listener..."
#    dnf install -y python3-pip
#    pip3 install docker==7.1.0 urllib3==1.26.20 requests==2.32.2
#    echo "✅ Dependencias docker-listener instaladas."
#else
#    echo "✅ Dependencias docker-listener ya presentes, se omite instalación."
#fi

# ---------------------------------------------------------------------------
# Transferir el control al punto de entrada original de la imagen del agente
# ---------------------------------------------------------------------------
exec /init "$@"