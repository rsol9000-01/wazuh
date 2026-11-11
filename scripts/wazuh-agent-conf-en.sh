#!/bin/sh
# ---------------------------------------------------------------------------
# Configurar el agente Wazuh después de iniciar el contenedor
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Detener la ejecución ante errores o variables sin definir
# ---------------------------------------------------------------------------
set -eu

# ---------------------------------------------------------------------------
# Instalar la configuración declarativa versionada en el repositorio
# ---------------------------------------------------------------------------
cp /opt/ossec.conf.tpl /var/ossec/etc/ossec.conf
chown root:wazuh /var/ossec/etc/ossec.conf
chmod 640 /var/ossec/etc/ossec.conf

# ---------------------------------------------------------------------------
# Preparar la contraseña de enrolamiento solo si el agente aún no está enrolado
# ---------------------------------------------------------------------------
if [ ! -s /var/ossec/etc/client.keys ]; then
    echo "🔑 client.keys not found: starting agent enrollment."
    cp /opt/authd.pass /var/ossec/etc/authd.pass
    chown root:wazuh /var/ossec/etc/authd.pass
    chmod 640 /var/ossec/etc/authd.pass
    echo "🔐 authd.pass permissions updated."
else
    echo "✅ client.keys found: skipping enrollment."
    rm -f /var/ossec/etc/authd.pass
fi

# ---------------------------------------------------------------------------
# Obtener la dirección del manager desde el argumento o el entorno
# ---------------------------------------------------------------------------
if [ -n "${1:-}" ]; then
    MANAGER="$1"
    shift
else
    MANAGER="${WAZUH_MANAGER_SERVER:-}"
fi

if [ -n "$MANAGER" ]; then
    echo "Wazuh manager server: ${MANAGER}"
    sed -i "/<server>/,/<\/server>/ s|<address>.*</address>|<address>${MANAGER}</address>|" \
        /var/ossec/etc/ossec.conf
fi

# ---------------------------------------------------------------------------
# Configurar el grupo de enrolamiento cuando esté definido
# ---------------------------------------------------------------------------
if [ -n "${WAZUH_AGENT_GROUP:-}" ]; then
    echo "Enrollment group: ${WAZUH_AGENT_GROUP}"
    sed -i "/<enrollment>/,/<\/enrollment>/ s|<groups>.*</groups>|<groups>${WAZUH_AGENT_GROUP}</groups>|" \
        /var/ossec/etc/ossec.conf
fi

# ---------------------------------------------------------------------------
# Configurar el nombre del agente durante el enrolamiento
# Con network_mode: host, definirlo explícitamente en <enrollment> porque
# Compose no puede asignar el nombre de host del contenedor.
# ---------------------------------------------------------------------------
if [ -n "${WAZUH_AGENT_NAME:-}" ]; then
    echo "Agent name: ${WAZUH_AGENT_NAME}"
    sed -i "/<enrollment>/,/<\/enrollment>/ s|<enabled>yes</enabled>|&\n      <agent_name>${WAZUH_AGENT_NAME}</agent_name>|" \
        /var/ossec/etc/ossec.conf
fi

# ---------------------------------------------------------------------------
# Transferir el control al punto de entrada original de la imagen
# ---------------------------------------------------------------------------
exec /init "$@"