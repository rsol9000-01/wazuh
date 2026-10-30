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

#──── 5. Entrypoint original de la imagen ──────────────────────────────
exec /init "$@"