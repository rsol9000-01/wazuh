#!/bin/sh
##########################################################################################
###### Script post-install for wazuh, executed by the wazuh-agents           #############
##########################################################################################

#──── Exit on error, e=exit on error, u=exit on undefined var ──────────
set -eu

#──── 1. Config declarativa: la fuente de verdad es el repo ────────────
cp /opt/ossec.conf.tpl /var/ossec/etc/ossec.conf
chown root:wazuh /var/ossec/etc/ossec.conf
chmod 640 /var/ossec/etc/ossec.conf

#──── 2. authd.pass solo si falta enrolarse ────────────────────────────
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

#──── 3. Dirección del manager: argumento o variable de entorno ────────
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

#──── 4. Grupo de enrolamiento ─────────────────────────────────────────
if [ -n "${WAZUH_AGENT_GROUP:-}" ]; then
    echo "Grupo de enrolamiento: ${WAZUH_AGENT_GROUP}"
    sed -i "/<enrollment>/,/<\/enrollment>/ s|<groups>.*</groups>|<groups>${WAZUH_AGENT_GROUP}</groups>|" \
        /var/ossec/etc/ossec.conf
fi

#──── 5. Nombre del agente (solo aplica al enrolarse) ──────────────────
#     Con network_mode: host no se puede fijar hostname en el compose,
#     así que el nombre se pasa explícito en <enrollment>.
if [ -n "${WAZUH_AGENT_NAME:-}" ]; then
    echo "Nombre del agente: ${WAZUH_AGENT_NAME}"
    sed -i "/<enrollment>/,/<\/enrollment>/ s|<enabled>yes</enabled>|&\n      <agent_name>${WAZUH_AGENT_NAME}</agent_name>|" \
        /var/ossec/etc/ossec.conf
fi

#──── 6. Entrypoint original de la imagen ──────────────────────────────
exec /init "$@"