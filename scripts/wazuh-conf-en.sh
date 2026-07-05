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
# Ejecutar el entrypoint original de la imagen del agente
exec /init "$@"