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
    echo "🔑 Sin client.keys: se va a enrolar."
    cp /opt/authd.pass /var/ossec/etc/authd.pass
    chown root:wazuh /var/ossec/etc/authd.pass
    chmod 640 /var/ossec/etc/authd.pass
    echo "🔐 Permisos de authd.pass ajustados."
else
    echo "✅ client.keys presente: no se re-enrola."
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
    echo "Grupo de enrolamiento: ${WAZUH_AGENT_GROUP}"
    sed -i "/<enrollment>/,/<\/enrollment>/ s|<groups>.*</groups>|<groups>${WAZUH_AGENT_GROUP}</groups>|" \
        /var/ossec/etc/ossec.conf
fi

# ---------------------------------------------------------------------------
# Configurar el nombre del agente durante el enrolamiento
# Con network_mode: host, definirlo explícitamente en <enrollment> porque
# Compose no puede asignar el nombre de host del contenedor.
# ---------------------------------------------------------------------------
if [ -n "${WAZUH_AGENT_NAME:-}" ]; then
    echo "Nombre del agente: ${WAZUH_AGENT_NAME}"
    sed -i "/<enrollment>/,/<\/enrollment>/ s|<enabled>yes</enabled>|&\n      <agent_name>${WAZUH_AGENT_NAME}</agent_name>|" \
        /var/ossec/etc/ossec.conf
fi

# ---------------------------------------------------------------------------
# Armar las politicas SCA (CIS) del host
# Las politicas oficiales evaluarian este contenedor. sca_host.py las reescribe
# la del sistema operativo del host (segun /host/etc/os-release) para leer
# /host y correr sus comandos en los namespaces del host. Si algo falla, se
# apaga SCA para no enviar un informe equivocado.
# ---------------------------------------------------------------------------
SCA_DIR=/var/ossec/etc/sca-host
rm -rf "$SCA_DIR"
if [ -d /host/etc ] && [ -d /opt/sca-src ] && python3 /opt/sca_host.py /opt/sca-src "$SCA_DIR"; then
    POLICIES=""
    for f in "$SCA_DIR"/*_host.yml; do
        POLICIES="${POLICIES}<policy>etc/sca-host/$(basename "$f")</policy>"
    done
    for f in /var/ossec/ruleset/sca/*.yml; do
        [ -e "$f" ] && POLICIES="${POLICIES}<policy enabled=\"no\">ruleset/sca/$(basename "$f")</policy>"
    done
    chown -R root:wazuh "$SCA_DIR"
    chmod 750 "$SCA_DIR"
    chmod 640 "$SCA_DIR"/*.yml
    sed -i "s|<!-- SCA_HOST_POLICIES -->|${POLICIES}|" /var/ossec/etc/ossec.conf
    echo "SCA: politicas del host activadas."
else
    sed -i "/<sca>/,/<\/sca>/ s|<enabled>yes</enabled>|<enabled>no</enabled>|" /var/ossec/etc/ossec.conf
    echo "SCA: sin vista del host (falta /host o /opt/sca-src). SCA apagado."
fi

# ---------------------------------------------------------------------------
# Transferir el control al punto de entrada original de la imagen
# ---------------------------------------------------------------------------
exec /init "$@"