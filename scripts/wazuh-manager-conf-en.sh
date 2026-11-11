#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Preparar el manager Wazuh antes de que se enrolen los agentes
# Crear los grupos, cargar sus configuraciones y reglas, validar los cambios
# y reiniciar el manager. Permitir volver a ejecutar el script sin duplicarlos.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Definir los colores usados en los mensajes del script
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Imprimir un título de sección con el color indicado
# ---------------------------------------------------------------------------

print_section() {
  local color="$1"
  local title="$2"
  echo ""
  echo -e "${color}-----------------------------------------------------${NC}"
  echo -e "${color}  ${title}${NC}"
  echo -e "${color}-----------------------------------------------------${NC}"
}

# ---------------------------------------------------------------------------
# Detener la ejecución ante errores o variables sin definir
# ---------------------------------------------------------------------------
set -eu

# ---------------------------------------------------------------------------
# Leer las credenciales, las opciones de TLS y las rutas de despliegue
# ---------------------------------------------------------------------------
API="${WAZUH_API_URL:-https://wazuh.manager:55000}"
USER="${WAZUH_API_USER:-wazuh-wui}"
PASS="${WAZUH_API_PASSWORD:?WAZUH_API_PASSWORD must be set in .env}"
INSECURE="${WAZUH_API_INSECURE:-0}"

# ---------------------------------------------------------------------------
# Definir las rutas del host y ajustarlas si el despliegue usa otras ubicaciones
# ---------------------------------------------------------------------------
DATABUS_PATH="${DATABUS_PATH:-/home/databus}"
INFOBUS_PATH="${INFOBUS_PATH:-/home/infobus}"
WAZUH_PATH="${WAZUH_PATH:-/home/wazuh}"
ZABBIX_PATH="${ZABBIX_PATH:-/home/zabbix}"

AGENT_GROUPS="databus infobus monitoring"

# ---------------------------------------------------------------------------
# Registrar un mensaje informativo en la salida estándar
# ---------------------------------------------------------------------------
log()  { echo "[INFO] $*"; }
# ---------------------------------------------------------------------------
# Mostrar una advertencia en la salida de error
# ---------------------------------------------------------------------------
warn() { echo "[WARN] $*" >&2; }
# ---------------------------------------------------------------------------
# Mostrar un error y finalizar el script
# ---------------------------------------------------------------------------
error()  { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Verificar las dependencias necesarias para consultar la API
# ---------------------------------------------------------------------------
command -v curl >/dev/null 2>&1 || { apk add --no-cache curl >/dev/null 2>&1 || error "curl is missing"; }
command -v jq   >/dev/null 2>&1 || { apk add --no-cache jq   >/dev/null 2>&1 || error "jq is missing"; }

CURL_TLS=""

if [ "$INSECURE" = "1" ]; then
    warn "(WAZUH_API_INSECURE=1). Use only on an internal network."
    CURL_TLS="-k"
else
    error "Explicitly set WAZUH_API_INSECURE=1."
fi

# ---------------------------------------------------------------------------
# Obtener y renovar el token de autenticación de la API antes de que expire
# El JWT tiene una vigencia de 900 segundos, por lo que renovarlo antes del
# reinicio evita usar un token vencido.
# ---------------------------------------------------------------------------
try_authenticate() {
    TOKEN=$(curl -s $CURL_TLS -u "${USER}:${PASS}" \
            -X POST "${API}/security/user/authenticate?raw=true" 2>/dev/null) || return 1
    case "$TOKEN" in
        ey*) return 0 ;;
        *)   return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Exigir que la API acepte las credenciales configuradas
# ---------------------------------------------------------------------------
authenticate() {
    try_authenticate || error "API rejected the credentials (user ${USER})"
}

# ---------------------------------------------------------------------------
# Esperar hasta que la API permita autenticarse o se agoten los reintentos
# ---------------------------------------------------------------------------
wait_for_api() {
    i=0
    until try_authenticate; do
        i=$((i + 1))
        [ "$i" -ge 36 ] && error "API did not accept credentials within 180 seconds"
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# Enviar una solicitud a la API con el método, la ruta y el cuerpo indicados
# ---------------------------------------------------------------------------
api() {
    _m="$1"; _p="$2"; _ct="${3:-}"; _b="${4:-}"
    if [ -n "$_ct" ]; then
        curl -s $CURL_TLS -X "$_m" "${API}${_p}" \
             -H "Authorization: Bearer ${TOKEN}" \
             -H "Content-Type: ${_ct}" \
             --data-binary "$_b"
    else
        curl -s $CURL_TLS -X "$_m" "${API}${_p}" \
             -H "Authorization: Bearer ${TOKEN}"
    fi
}

# ---------------------------------------------------------------------------
# Validar la respuesta y detenerse ante errores no tolerados
# ---------------------------------------------------------------------------
check() {
    _resp="$1"; _what="$2"
    if echo "$_resp" | jq -e '.title? // (.error? | select(. != 0))' >/dev/null 2>&1; then
        warn "Response: $_resp"
        error "${_what}: API rejected the operation"
    fi
    log "  ${_what}: ok"
}

log "Waiting for the API at ${API} ..."
wait_for_api
log "API is available. Authenticated as ${USER}."

# ---------------------------------------------------------------------------
# Crear los grupos de agentes si todavía no existen
# ---------------------------------------------------------------------------
log "Creating groups ..."
for g in $AGENT_GROUPS; do
    if api GET "/groups?groups_list=${g}" \
         | jq -e --arg g "$g" '.data.affected_items[]? | select(.name == $g)' >/dev/null 2>&1; then
        log "  group ${g}: already exists"
    else
        r=$(api POST "/groups" "application/json" "{\"group_id\":\"${g}\"}")
        check "$r" "grupo ${g}"
    fi
done

# ---------------------------------------------------------------------------
# Configurar la recopilación de logs y la integridad del grupo databus
# ---------------------------------------------------------------------------
# Excluir las diferencias de los archivos de entorno para evitar que sus
# contenidos sensibles aparezcan en las alertas de integridad.
# ---------------------------------------------------------------------------
log "Uploading agent.conf for the databus group ..."
AGENT_CONF_DATABUS=$(cat <<XML
<agent_config>

  <localfile>
    <log_format>json</log_format>
    <location>/var/lib/docker/containers/*/*-json.log</location>
  </localfile>

  <syscheck>
    <disabled>no</disabled>
    <scan_on_start>yes</scan_on_start>

    <directories check_all="yes" realtime="yes">${DATABUS_PATH}</directories>
    <directories check_all="yes" realtime="yes">/var/lib/docker/volumes/databus_feed_files/_data</directories>

    <nodiff>${DATABUS_PATH}/.env</nodiff>
    <nodiff>${DATABUS_PATH}/.env.prod</nodiff>
    <ignore>${DATABUS_PATH}/.git</ignore>
    <ignore type="sregex">\\.log\$|\\.tmp\$|/__pycache__/</ignore>
  </syscheck>

</agent_config>
XML
)
r=$(api PUT "/groups/databus/configuration" "application/xml" "$AGENT_CONF_DATABUS")
check "$r" "agent.conf de databus"

# ---------------------------------------------------------------------------
# Configurar la recopilación de logs y la integridad del grupo infobus
# ---------------------------------------------------------------------------
log "Uploading agent.conf for the infobus group ..."
AGENT_CONF_INFOBUS=$(cat <<XML
<agent_config>

  <localfile>
    <log_format>json</log_format>
    <location>/var/lib/docker/containers/*/*-json.log</location>
  </localfile>

  <syscheck>
    <disabled>no</disabled>
    <scan_on_start>yes</scan_on_start>

    <directories check_all="yes" realtime="yes">${INFOBUS_PATH}</directories>

    <nodiff>${INFOBUS_PATH}/.env</nodiff>
    <nodiff>${INFOBUS_PATH}/.env.prod</nodiff>

    <ignore>${INFOBUS_PATH}/.git</ignore>
    <ignore type="sregex">\\.log\$|\\.tmp\$|/__pycache__/</ignore>
  </syscheck>

</agent_config>
XML
)
r=$(api PUT "/groups/infobus/configuration" "application/xml" "$AGENT_CONF_INFOBUS")
check "$r" "agent.conf de infobus"

# ---------------------------------------------------------------------------
# Configurar la recopilación de logs y la integridad del grupo monitoring
# ---------------------------------------------------------------------------
# Usar auth.log como fuente con dirección IP de origen para validar respuestas
# activas en el host que ejecuta el monitoreo.
# ---------------------------------------------------------------------------
log "Uploading agent.conf for the monitoring group ..."
AGENT_CONF_MONITORING=$(cat <<XML
<agent_config>

  <!-- Unica fuente del proyecto que trae srcip: es donde la respuesta
       activa se puede demostrar. -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <localfile>
    <log_format>json</log_format>
    <location>/var/lib/docker/containers/*/*-json.log</location>
  </localfile>

  <!-- Integridad de la configuracion del propio sistema de monitoreo.
       Los .env de ambos stacks concentran todas las credenciales. -->
  <syscheck>
    <disabled>no</disabled>
    <scan_on_start>yes</scan_on_start>

    <directories check_all="yes" realtime="yes">${WAZUH_PATH}</directories>
    <directories check_all="yes" realtime="yes">${ZABBIX_PATH}</directories>

    <nodiff>${WAZUH_PATH}/.env</nodiff>
    <nodiff>${ZABBIX_PATH}/.env</nodiff>
    <nodiff>${WAZUH_PATH}/config/wazuh_cluster/authd.pass</nodiff>

    <ignore>${WAZUH_PATH}/.git</ignore>
    <ignore>${ZABBIX_PATH}/.git</ignore>
    <ignore>${WAZUH_PATH}/config/wazuh_indexer_ssl_certs</ignore>
    <ignore type="sregex">\\.log\$|\\.tmp\$|/__pycache__/</ignore>
  </syscheck>

</agent_config>
XML
)
r=$(api PUT "/groups/monitoring/configuration" "application/xml" "$AGENT_CONF_MONITORING")
check "$r" "agent.conf de monitoring"

# ---------------------------------------------------------------------------
# Cargar las reglas propias del proyecto dentro del rango reservado
# ---------------------------------------------------------------------------
log "Uploading local_rules.xml ..."
LOCAL_RULES=$(cat <<'XML'
<group name="simovilab,">

  <!-- Reglas del TFG - monitoreo de databus/infobus (simovilab, UCR).
       Cada regla corresponde a un hallazgo documentado en 7.3.1.
       Rango reservado para reglas propias: 100000+. -->

  <rule id="100100" level="0">
    <decoded_as>json</decoded_as>
    <field name="stream">stdout|stderr</field>
    <description>Docker container log line</description>
  </rule>

  <!-- R1: fallo de importacion del GTFS (H11) -->
  <rule id="100101" level="10">
    <if_sid>100100</if_sid>
    <field name="log">GTFS Schedule bootstrap failed|Import failed for provider|IntegrityError</field>
    <description>databus: GTFS Schedule import failed</description>
    <group>gtfs_integrity,</group>
  </rule>

  <!-- R2: host HTTP rechazado (H12) -->
  <rule id="100102" level="8">
    <if_sid>100100</if_sid>
    <field name="log">DisallowedHost|Invalid HTTP_HOST header</field>
    <description>Request rejected by ALLOWED_HOSTS</description>
    <group>recon,</group>
  </rule>

  <rule id="100103" level="12" frequency="8" timeframe="120">
    <if_matched_sid>100102</if_matched_sid>
    <description>Host name scan: 8 requests rejected within 120 s</description>
    <group>recon,</group>
  </rule>

  <!-- R3: error 5xx de la aplicacion -->
  <rule id="100104" level="7">
    <if_sid>100100</if_sid>
    <field name="log">Internal Server Error:</field>
    <description>Django 5xx response</description>
  </rule>

  <!-- R4: enumeracion de rutas -->
  <rule id="100105" level="3">
    <if_sid>100100</if_sid>
    <field name="log">Not Found: </field>
    <description>404 response for a nonexistent route</description>
  </rule>

  <rule id="100106" level="10" frequency="20" timeframe="60">
    <if_matched_sid>100105</if_matched_sid>
    <description>Burst of 404 responses: route enumeration</description>
    <group>recon,</group>
  </rule>

  <!-- R5: autenticacion fallida en Redis -->
  <rule id="100107" level="9">
    <if_sid>100100</if_sid>
    <field name="log">WRONGPASS|NOAUTH</field>
    <description>Redis authentication failed</description>
    <group>authentication_failed,</group>
  </rule>

  <!-- R6: reintento infinito en el flujo de eventos (H9, infobus) -->
   <rule id="100108" level="3">
    <if_sid>100100</if_sid>
    <field name="log">Failed to process update event</field>
    <description>infobus: failed to process an update event</description>
  </rule>

  <rule id="100110" level="7" frequency="5" timeframe="300">
    <if_matched_sid>100108</if_matched_sid>
    <description>infobus: event retried without limit and without dead-letter handling</description>
    <group>gtfs_integrity,</group>
  </rule>

  <!-- R7: codigo clonado desde la red en arranque (H15) -->
  <rule id="100109" level="6">
    <if_sid>100100</if_sid>
    <field name="log">Cloning gtfs-\w+ repository</field>
    <description>databus: code cloned from GitHub during a cold start</description>
    <group>supply_chain,</group>
  </rule>

  <!-- R8: cambio en configuracion o secretos -->
  <rule id="100120" level="12">
    <if_sid>550,553,554</if_sid>
    <field name="file">.env|compose.prod.yml</field>
    <description>Deployment configuration or secrets changed</description>
    <group>syscheck,</group>
  </rule>

  <!-- R9: cambio en el GTFS publicado -->
  <rule id="100121" level="10">
    <if_sid>550,553,554</if_sid>
    <field name="file">databus_feed_files</field>
    <description>databus: published GTFS Schedule changed</description>
    <group>syscheck,gtfs_integrity,</group>
  </rule>

  <!-- R10: socket de Docker (riesgo aceptado) -->
  <rule id="100122" level="12">
    <if_sid>550,554</if_sid>
    <field name="file">docker.sock</field>
    <description>Docker socket changed</description>
    <group>syscheck,</group>
  </rule>

   <!-- R11: eventos malformados enviados a la cola muerta (infobus) -->
  <rule id="100111" level="5">
    <if_sid>100100</if_sid>
    <field name="log">Invalid update event</field>
    <description>infobus: malformed update event sent to the dead-letter queue</description>
  </rule>

  <rule id="100112" level="9" frequency="10" timeframe="600">
    <if_matched_sid>100111</if_matched_sid>
    <description>infobus: producer is continuously sending malformed events</description>
    <group>availability,</group>
  </rule>

</group>
XML
)
#r=$(api PUT "/rules/files/local_rules.xml?overwrite=true" "application/octet-stream" "$LOCAL_RULES")
printf '%s\n' "$LOCAL_RULES" > /tmp/local_rules.xml
r=$(curl -s $CURL_TLS -X PUT "${API}/rules/files/local_rules.xml?overwrite=true" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary @/tmp/local_rules.xml)

check "$r" "local_rules.xml"

# ---------------------------------------------------------------------------
# Validar la configuración antes de reiniciar el manager
# ---------------------------------------------------------------------------
log "Validating the manager configuration ..."
status=""
i=0
while [ "$i" -lt 6 ]; do
    r=$(api GET "/manager/configuration/validation")
    status=$(echo "$r" | jq -r '(.data.affected_items[0].status // .data.status // "unknown")' 2>/dev/null)
    [ "$status" = "OK" ] && break
    i=$((i + 1))
    warn "Validation attempt ${i}/6: status=${status:-empty}"
    sleep 5
done

if [ "$status" != "OK" ]; then
    warn "Response: $r"
    echo "$r" | jq -r '.data.affected_items[0].details[]? // empty' >&2 || true
    error "Configuration is invalid (status=${status:-empty}); the manager will NOT be restarted"
fi
log "  Configuration is valid."
# ---------------------------------------------------------------------------
# Renovar el token y reiniciar el manager
# ---------------------------------------------------------------------------
# Reautenticar antes del reinicio para evitar usar un JWT que haya expirado.
# ---------------------------------------------------------------------------
authenticate
log "Restarting the manager ..."
r=$(api PUT "/manager/restart")
check "$r" "reinicio del manager"

sleep 10
wait_for_api
log "API is available after the restart."

# ---------------------------------------------------------------------------
# Mostrar el resumen de grupos y las instrucciones de enrolamiento
# ---------------------------------------------------------------------------

log "Existing groups:"
api GET "/groups" | jq -r '.data.affected_items[] | "  - \(.name) (agentes: \(.count))"'

log "Done. The manager is ready to accept registrations; agents can enroll in:"
log "  R3 -> group 'databus'   R2 -> group 'infobus'   R4 -> group 'monitoring'"
exit 0