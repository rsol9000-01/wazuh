#!/usr/bin/env bash
#
# wazuh-manager-conf.sh — prepara el manager ANTES de que exista cualquier agente.
#
# Crea los grupos, sube el agent.conf de cada grupo y las reglas propias
# del proyecto vía la API de Wazuh (55000), valida la configuración,
# reinicia el manager y termina. Es idempotente: se puede volver a correr.

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Print a consistently formatted section title with a chosen color
# ---------------------------------------------------------------------------

print_section() {
  local color="$1"
  local title="$2"
  echo ""
  echo -e "${color}-----------------------------------------------------${NC}"
  echo -e "${color}  ${title}${NC}"
  echo -e "${color}-----------------------------------------------------${NC}"
}

set -eu

# ─────────────────────────────────────────────────────────────────────
# Parámetros
# ─────────────────────────────────────────────────────────────────────
API="${WAZUH_API_URL:-https://wazuh.manager:55000}"
USER="${WAZUH_API_USER:-wazuh-wui}"
PASS="${WAZUH_API_PASSWORD:?WAZUH_API_PASSWORD must be set in .env}"
INSECURE="${WAZUH_API_INSECURE:-0}"

# Ruta del despliegue de databus EN EL HOST. Ajustar si difiere.
DATABUS_PATH="${DATABUS_PATH:-/opt/databus}"

AGENT_GROUPS="databus infobus monitoring"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
error()  { echo "[ERROR] $*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────
# Proof for TLS or insecure mode. curl y jq son necesarios para la API.
# ─────────────────────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || { apk add --no-cache curl >/dev/null 2>&1 || error "falta curl"; }
command -v jq   >/dev/null 2>&1 || { apk add --no-cache jq   >/dev/null 2>&1 || error "falta jq"; }

CURL_TLS=""

if [ "$INSECURE" = "1" ]; then
    warn "(WAZUH_API_INSECURE=1). Aceptable solo en red interna."
    CURL_TLS="-k"
else
    error "Defina WAZUH_API_INSECURE=1 de forma explícita."
fi

# ─────────────────────────────────────────────────────────────────────
# Esperar a que la API responda
# ─────────────────────────────────────────────────────────────────────
log "Esperando la API en ${API} ..."
wait_for_api
log "API disponible y autenticada como ${USER}."

# ─────────────────────────────────────────────────────────────────────
# Autenticación. El JWT dura 900 s; se refresca antes del reinicio.
# ─────────────────────────────────────────────────────────────────────
try_authenticate() {
    TOKEN=$(curl -s $CURL_TLS -u "${USER}:${PASS}" \
            -X POST "${API}/security/user/authenticate?raw=true" 2>/dev/null) || return 1
    case "$TOKEN" in
        ey*) return 0 ;;
        *)   return 1 ;;
    esac
}

authenticate() {
    try_authenticate || error "credenciales rechazadas por la API (usuario ${USER})"
}

wait_for_api() {
    i=0
    until try_authenticate; do
        i=$((i + 1))
        [ "$i" -ge 36 ] && error "la API no acepto credenciales en 180 s"
        sleep 5
    done
}

# api <método> <ruta> [content-type] [cuerpo]
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

# Falla si la respuesta trae error distinto del "ya existe" que toleramos.
check() {
    _resp="$1"; _what="$2"
    if echo "$_resp" | jq -e '.title? // (.error? | select(. != 0))' >/dev/null 2>&1; then
        warn "respuesta: $_resp"
        error "${_what}: la API rechazó la operación"
    fi
    log "  ${_what}: ok"
}

log "Esperando la API en ${API} ..."
wait_for_api
log "API disponible. Autenticado como ${USER}."

# ─────────────────────────────────────────────────────────────────────
# 1. Grupos de agentes
# ─────────────────────────────────────────────────────────────────────
log "Creando grupos ..."
for g in $AGENT_GROUPS; do
    if api GET "/groups?groups_list=${g}" \
         | jq -e --arg g "$g" '.data.affected_items[]? | select(.name == $g)' >/dev/null 2>&1; then
        log "  grupo ${g}: ya existe"
    else
        r=$(api POST "/groups" "application/json" "{\"group_id\":\"${g}\"}")
        check "$r" "grupo ${g}"
    fi
done

# ─────────────────────────────────────────────────────────────────────
# 2. agent.conf del grupo databus (R3)
#
#    El <nodiff> no es opcional: sin él la alerta de FIM viaja al manager
#    con el contenido del archivo, y SECRET_KEY, DB_PASSWORD, RABBITMQ_PASS
#    y API_TOKEN quedarían en claro en el log de alertas.
# ─────────────────────────────────────────────────────────────────────
log "Subiendo agent.conf del grupo databus ..."
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
    <directories check_all="yes" realtime="yes">/etc/systemd</directories>
    <directories check_all="yes">/usr/bin,/usr/sbin</directories>

    <nodiff>${DATABUS_PATH}/.env</nodiff>
    <nodiff>${DATABUS_PATH}/.env.prod</nodiff>

    <ignore type="sregex">\.log$|\.tmp$|/__pycache__/</ignore>
  </syscheck>

</agent_config>
XML
)
r=$(api PUT "/groups/databus/configuration" "application/xml" "$AGENT_CONF_DATABUS")
check "$r" "agent.conf de databus"

# ─────────────────────────────────────────────────────────────────────
# 3. agent.conf del grupo infobus (R2)
# ─────────────────────────────────────────────────────────────────────
log "Subiendo agent.conf del grupo infobus ..."
AGENT_CONF_INFOBUS=$(cat <<'XML'
<agent_config>

  <localfile>
    <log_format>json</log_format>
    <location>/var/lib/docker/containers/*/*-json.log</location>
  </localfile>

  <syscheck>
    <disabled>no</disabled>
    <scan_on_start>yes</scan_on_start>
    <directories check_all="yes" realtime="yes">/etc/systemd</directories>
    <directories check_all="yes">/usr/bin,/usr/sbin</directories>
    <ignore type="sregex">\.log$|\.tmp$|/__pycache__/</ignore>
  </syscheck>

</agent_config>
XML
)
r=$(api PUT "/groups/infobus/configuration" "application/xml" "$AGENT_CONF_INFOBUS")
check "$r" "agent.conf de infobus"

# ─────────────────────────────────────────────────────────────────────
# 4. agent.conf del grupo monitoring (R4, host propio)
#    Es el único con una fuente que trae srcip, así que es donde la
#    respuesta activa se puede demostrar de verdad.
# ─────────────────────────────────────────────────────────────────────
log "Subiendo agent.conf del grupo monitoring ..."
AGENT_CONF_MONITORING=$(cat <<'XML'
<agent_config>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <syscheck>
    <disabled>no</disabled>
    <scan_on_start>yes</scan_on_start>
    <directories check_all="yes" realtime="yes">/etc</directories>
    <directories check_all="yes">/usr/bin,/usr/sbin</directories>
    <ignore>/etc/mtab</ignore>
    <ignore>/etc/resolv.conf</ignore>
    <ignore type="sregex">\.log$|\.tmp$</ignore>
  </syscheck>

</agent_config>
XML
)
r=$(api PUT "/groups/monitoring/configuration" "application/xml" "$AGENT_CONF_MONITORING")
check "$r" "agent.conf de monitoring"

# ─────────────────────────────────────────────────────────────────────
# 5. Reglas propias del proyecto (rango 100100–100199)
# ─────────────────────────────────────────────────────────────────────
log "Subiendo local_rules.xml ..."
LOCAL_RULES=$(cat <<'XML'
<group name="simovilab,">

  <!-- Reglas del TFG - monitoreo de databus/infobus (simovilab, UCR).
       Cada regla corresponde a un hallazgo documentado en 7.3.1.
       Rango reservado para reglas propias: 100000+. -->

  <rule id="100100" level="0">
    <decoded_as>json</decoded_as>
    <field name="stream">stdout|stderr</field>
    <description>Linea de log de contenedor Docker</description>
  </rule>

  <!-- R1: fallo de importacion del GTFS (H11) -->
  <rule id="100101" level="10">
    <if_sid>100100</if_sid>
    <field name="log">GTFS Schedule bootstrap failed|Import failed for provider|IntegrityError</field>
    <description>databus: fallo al importar el GTFS Schedule</description>
    <group>gtfs_integrity,</group>
  </rule>

  <!-- R2: host HTTP rechazado (H12) -->
  <rule id="100102" level="8">
    <if_sid>100100</if_sid>
    <field name="log">DisallowedHost|Invalid HTTP_HOST header</field>
    <description>databus: peticion rechazada por ALLOWED_HOSTS</description>
    <group>recon,</group>
  </rule>

  <rule id="100103" level="12" frequency="8" timeframe="120">
    <if_matched_sid>100102</if_matched_sid>
    <description>databus: barrido de nombres de host, 8 rechazos en 120 s</description>
    <group>recon,</group>
  </rule>

  <!-- R3: error 5xx de la aplicacion -->
  <rule id="100104" level="7">
    <if_sid>100100</if_sid>
    <field name="log">Internal Server Error:</field>
    <description>databus: respuesta 5xx de Django</description>
  </rule>

  <!-- R4: enumeracion de rutas -->
  <rule id="100105" level="3">
    <if_sid>100100</if_sid>
    <field name="log">Not Found: </field>
    <description>databus: 404</description>
  </rule>

  <rule id="100106" level="10" frequency="20" timeframe="60">
    <if_matched_sid>100105</if_matched_sid>
    <description>databus: rafaga de 404, enumeracion de rutas</description>
    <group>recon,</group>
  </rule>

  <!-- R5: autenticacion fallida en Redis -->
  <rule id="100107" level="9">
    <if_sid>100100</if_sid>
    <field name="log">WRONGPASS|NOAUTH</field>
    <description>databus: autenticacion fallida contra Redis</description>
    <group>authentication_failed,</group>
  </rule>

  <!-- R6: reintento infinito en el flujo de eventos (H9, infobus) -->
   <rule id="100108" level="3">
    <if_sid>100100</if_sid>
    <field name="log">Failed to process update event</field>
    <description>infobus: fallo al procesar un evento de actualizacion</description>
  </rule>

  <rule id="100110" level="7" frequency="5" timeframe="300">
    <if_matched_sid>100108</if_matched_sid>
    <description>infobus: evento reprocesado sin limite, sin dead-letter</description>
    <group>gtfs_integrity,</group>
  </rule>

  <!-- R7: codigo clonado desde la red en arranque (H15) -->
  <rule id="100109" level="6">
    <if_sid>100100</if_sid>
    <field name="log">Cloning gtfs-\w+ repository</field>
    <description>databus: codigo clonado desde GitHub en arranque en frio</description>
    <group>supply_chain,</group>
  </rule>

  <!-- R8: cambio en configuracion o secretos -->
  <rule id="100120" level="12">
    <if_sid>550,553,554</if_sid>
    <field name="file">.env|compose.prod.yml</field>
    <description>databus: cambio en configuracion o secretos del despliegue</description>
    <group>syscheck,</group>
  </rule>

  <!-- R9: cambio en el GTFS publicado -->
  <rule id="100121" level="10">
    <if_sid>550,553,554</if_sid>
    <field name="file">databus_feed_files</field>
    <description>databus: cambio en el GTFS Schedule publicado</description>
    <group>syscheck,gtfs_integrity,</group>
  </rule>

  <!-- R10: socket de Docker (riesgo aceptado) -->
  <rule id="100122" level="12">
    <if_sid>550,554</if_sid>
    <field name="file">docker.sock</field>
    <description>Cambio en el socket de Docker</description>
    <group>syscheck,</group>
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

# ─────────────────────────────────────────────────────────────────────
# 6. Validar ANTES de reiniciar. Un XML malo deja el manager caído.
# ─────────────────────────────────────────────────────────────────────
log "Validando la configuración del manager ..."
r=$(api GET "/manager/configuration/validation")
status=$(echo "$r" | jq -r '.data.affected_items[0].status // "unknown"')
if [ "$status" != "OK" ]; then
    echo "$r" | jq -r '.data.affected_items[0].details[]?' >&2 || true
    error "la configuración no valida; NO se reinicia el manager"
fi
log "  configuración válida."

# ─────────────────────────────────────────────────────────────────────
# 7. Reiniciar el manager y esperar a que vuelva
# ─────────────────────────────────────────────────────────────────────
authenticate          # el JWT pudo expirar durante los pasos anteriores
log "Reiniciando el manager ..."
r=$(api PUT "/manager/restart")
check "$r" "reinicio del manager"

sleep 10
wait_for_api
log "API lista tras el reinicio."

# ─────────────────────────────────────────────────────────────────────
# 8. Resumen
# ─────────────────────────────────────────────────────────────────────

log "Grupos existentes:"
api GET "/groups" | jq -r '.data.affected_items[] | "  - \(.name) (agentes: \(.count))"'

log "Listo. El manager acepta registros; los agentes pueden enrolarse con:"
log "  R3 -> grupo 'databus'   R2 -> grupo 'infobus'   R4 -> grupo 'monitoring'"
exit 0