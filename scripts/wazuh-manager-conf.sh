#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Prepare the Wazuh manager before agents enroll
# Create groups, upload their configurations and rules, validate the changes,
# and restart the manager. Allow the script to be run again without duplicates.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Define the colors used in script messages
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Print a section heading in the specified color
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
# Stop execution on errors or undefined variables
# ---------------------------------------------------------------------------
set -eu

# ---------------------------------------------------------------------------
# Read the credentials, TLS options, and deployment paths
# ---------------------------------------------------------------------------
API="${WAZUH_API_URL:-https://wazuh.manager:55000}"
USER="${WAZUH_API_USER:-wazuh-wui}"
PASS="${WAZUH_API_PASSWORD:?WAZUH_API_PASSWORD must be set in .env}"
INSECURE="${WAZUH_API_INSECURE:-0}"

# ---------------------------------------------------------------------------
# Define host paths and adjust them if the deployment uses different locations
# ---------------------------------------------------------------------------
DATABUS_PATH="${DATABUS_PATH:-/home/databus}"
INFOBUS_PATH="${INFOBUS_PATH:-/home/infobus}"
WAZUH_PATH="${WAZUH_PATH:-/home/wazuh}"
ZABBIX_PATH="${ZABBIX_PATH:-/home/zabbix}"

AGENT_GROUPS="databus infobus monitoring"

# ---------------------------------------------------------------------------
# Log an informational message to standard output
# ---------------------------------------------------------------------------
log()  { echo "[INFO] $*"; }
# ---------------------------------------------------------------------------
# Display a warning on standard error
# ---------------------------------------------------------------------------
warn() { echo "[WARN] $*" >&2; }
# ---------------------------------------------------------------------------
# Display an error and exit the script
# ---------------------------------------------------------------------------
error()  { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Check the dependencies required to query the API
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
# Get and renew the API authentication token before it expires
# The JWT is valid for 900 seconds, so renewing it before the restart avoids
# using an expired token.
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
# Require the API to accept the configured credentials
# ---------------------------------------------------------------------------
authenticate() {
    try_authenticate || error "API rejected the credentials (user ${USER})"
}

# ---------------------------------------------------------------------------
# Wait until authentication succeeds or the retries are exhausted
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
# Send an API request using the specified method, path, and body
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
# Validate the response and stop on unexpected errors
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
# Create the agent groups if they do not already exist
# ---------------------------------------------------------------------------
log "Creating groups ..."
for g in $AGENT_GROUPS; do
    if api GET "/groups?groups_list=${g}" \
         | jq -e --arg g "$g" '.data.affected_items[]? | select(.name == $g)' >/dev/null 2>&1; then
        log "  group ${g}: already exists"
    else
        r=$(api POST "/groups" "application/json" "{\"group_id\":\"${g}\"}")
        check "$r" "group ${g}"
    fi
done

# ---------------------------------------------------------------------------
# Configure log collection and integrity monitoring for the databus group
# ---------------------------------------------------------------------------
# Exclude environment-file differences so their sensitive contents do not
# appear in integrity alerts.
# ---------------------------------------------------------------------------
log "Uploading agent.conf for the databus group ..."
AGENT_CONF_DATABUS=$(cat <<XML
<agent_config>

  <!-- SSH (sshd) with source IP: rules 5712, 5720 and 5763 and their
       active response also protect this host. -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <localfile>
    <log_format>json</log_format>
    <location>/var/lib/docker/containers/*/*-json.log</location>
  </localfile>

  <!-- Traefik access log: one JSON line per request, with the client IP (ClientHost). -->
  <localfile>
    <log_format>json</log_format>
    <location>/home/traefik/logs/access.log</location>
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
check "$r" "agent.conf for databus"

# ---------------------------------------------------------------------------
# Configure log collection and integrity monitoring for the infobus group
# ---------------------------------------------------------------------------
log "Uploading agent.conf for the infobus group ..."
AGENT_CONF_INFOBUS=$(cat <<XML
<agent_config>

  <!-- SSH (sshd) with source IP: rules 5712, 5720 and 5763 and their
       active response also protect this host. -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <localfile>
    <log_format>json</log_format>
    <location>/var/lib/docker/containers/*/*-json.log</location>
  </localfile>

  <!-- Traefik access log: one JSON line per request, with the client IP (ClientHost). -->
  <localfile>
    <log_format>json</log_format>
    <location>/home/traefik/logs/access.log</location>
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
check "$r" "agent.conf for infobus"

# ---------------------------------------------------------------------------
# Configure log collection and integrity monitoring for the monitoring group
# ---------------------------------------------------------------------------
# auth.log (SSH with source IP) feeds the active response on this host, the
# same as in the databus and infobus groups.
# ---------------------------------------------------------------------------
log "Uploading agent.conf for the monitoring group ..."
AGENT_CONF_MONITORING=$(cat <<XML
<agent_config>

  <!-- SSH (sshd) with source IP: rules 5712, 5720 and 5763 and their
       active response protect this host. -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <localfile>
    <log_format>json</log_format>
    <location>/var/lib/docker/containers/*/*-json.log</location>
  </localfile>

  <!-- Traefik access log: one JSON line per request, with the client IP (ClientHost). -->
  <localfile>
    <log_format>json</log_format>
    <location>/home/traefik/logs/access.log</location>
  </localfile>

  <!-- Integrity monitoring for the monitoring system itself.
       The .env files for both stacks contain all credentials. -->
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
check "$r" "agent.conf for monitoring"

# ---------------------------------------------------------------------------
# Load project-specific rules within the reserved range
# ---------------------------------------------------------------------------
log "Uploading local_rules.xml ..."
LOCAL_RULES=$(cat <<'XML'
<group name="simovilab,">

  <!-- Thesis-project rules for databus/infobus monitoring (simovilab, UCR).
       Each rule corresponds to a finding documented in section 7.3.1.
       Range reserved for custom rules: 100000+. -->

  <rule id="100100" level="0">
    <decoded_as>json</decoded_as>
    <field name="stream">stdout|stderr</field>
    <description>Docker container log line</description>
  </rule>

  <!-- R1: GTFS import failure (H11) -->
  <rule id="100101" level="10">
    <if_sid>100100</if_sid>
    <field name="log">GTFS Schedule bootstrap failed|Import failed for provider|IntegrityError</field>
    <description>databus: GTFS Schedule import failed</description>
    <group>gtfs_integrity,</group>
  </rule>

  <!-- R2: HTTP host rejected (H12) -->
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

  <!-- R3: application 5xx error -->
  <rule id="100104" level="7">
    <if_sid>100100</if_sid>
    <field name="log">Internal Server Error:</field>
    <description>Django 5xx response</description>
  </rule>

  <!-- R4: route enumeration -->
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

  <!-- R5: Redis authentication failure -->
  <rule id="100107" level="9">
    <if_sid>100100</if_sid>
    <field name="log">WRONGPASS|NOAUTH</field>
    <description>Redis authentication failed</description>
    <group>authentication_failed,</group>
  </rule>

  <!-- R6: unlimited retries in the event stream (H9, infobus) -->
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

  <!-- R7: code cloned from the network during startup (H15) -->
  <rule id="100109" level="6">
    <if_sid>100100</if_sid>
    <field name="log">Cloning gtfs-\w+ repository</field>
    <description>databus: code cloned from GitHub during a cold start</description>
    <group>supply_chain,</group>
  </rule>

  <!-- R8: configuration or secrets changed -->
  <rule id="100120" level="12">
    <if_sid>550,553,554</if_sid>
    <field name="file">.env|compose.prod.yml</field>
    <description>Deployment configuration or secrets changed</description>
    <group>syscheck,</group>
  </rule>

  <!-- R9: published GTFS changed -->
  <rule id="100121" level="10">
    <if_sid>550,553,554</if_sid>
    <field name="file">databus_feed_files</field>
    <description>databus: published GTFS Schedule changed</description>
    <group>syscheck,gtfs_integrity,</group>
  </rule>

  <!-- R10: Docker socket (accepted risk) -->
  <rule id="100122" level="12">
    <if_sid>550,554</if_sid>
    <field name="file">docker.sock</field>
    <description>Docker socket changed</description>
    <group>syscheck,</group>
  </rule>

   <!-- R11: malformed events sent to the dead-letter queue (infobus) -->
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

  <!-- R12: Traefik access log (JSON). Detection by ClientHost works with the built-in
       json fields; the local decoder simovilab-traefik also copies ClientHost
       into srcip so active responses can block the client. -->
  <rule id="100130" level="0">
    <decoded_as>json</decoded_as>
    <field name="entryPointName">\.+</field>
    <field name="ClientHost">\.+</field>
    <description>Traefik: request in the access log</description>
  </rule>

  <rule id="100131" level="5">
    <if_sid>100130</if_sid>
    <field name="DownstreamStatus" type="pcre2">^40[13]$</field>
    <description>Traefik: access denied ($(DownstreamStatus)) to $(RequestHost) from $(ClientHost)</description>
    <group>web,access_denied,</group>
  </rule>

  <rule id="100132" level="10" frequency="20" timeframe="60">
    <if_matched_sid>100131</if_matched_sid>
    <same_field>ClientHost</same_field>
    <description>Traefik: brute force, 20 denied requests (401/403) in 60 s from $(ClientHost)</description>
    <mitre><id>T1110</id></mitre>
    <group>web,authentication_failures,</group>
  </rule>

  <rule id="100133" level="3">
    <if_sid>100130</if_sid>
    <field name="DownstreamStatus" type="pcre2">^404$</field>
    <description>Traefik: 404 for $(RequestPath) from $(ClientHost)</description>
  </rule>

  <rule id="100134" level="10" frequency="50" timeframe="60">
    <if_matched_sid>100133</if_matched_sid>
    <same_field>ClientHost</same_field>
    <different_field>RequestPath</different_field>
    <description>Traefik: route scan, 50 different nonexistent paths in 60 s from $(ClientHost)</description>
    <mitre><id>T1595</id></mitre>
    <group>web,recon,</group>
  </rule>

  <rule id="100135" level="10" frequency="3000" timeframe="30">
    <if_matched_sid>100130</if_matched_sid>
    <same_field>ClientHost</same_field>
    <description>Traefik: flooding, 3000 requests in 30 s (100 req/s) from $(ClientHost)</description>
    <group>web,dos,</group>
  </rule>

  <!-- Same missing route requested over and over, from any client: points to a
       client with a stale or broken URL (a screen, an app, a probe), not an
       attack. Alert only, no active response. ignore=60 keeps it to at
       most one alert per minute while the problem lasts; each 404 is still
       raised by 100133 during that minute. -->
  <rule id="100136" level="7" frequency="50" timeframe="60" ignore="60">
    <if_matched_sid>100133</if_matched_sid>
    <same_field>RequestHost</same_field>
    <same_field>RequestPath</same_field>
    <description>Traefik: missing route requested 50 times in 60 s: $(RequestHost)$(RequestPath). Check why clients request it</description>
    <group>web,availability,</group>
  </rule>

  <!-- R13: Django admin login (databus and infobus). A failed login answers
       200 (the form is shown again) and a correct one answers 302; Django
       does not log the failure and does not limit attempts, so the Traefik
       access log is the only source. -->
  <rule id="100137" level="5">
    <if_sid>100130</if_sid>
    <field name="RequestMethod" type="pcre2">^POST$</field>
    <field name="RequestPath" type="pcre2">^/admin/login/</field>
    <field name="DownstreamStatus" type="pcre2">^200$</field>
    <description>Traefik: failed Django admin login on $(RequestHost) from $(ClientHost)</description>
    <group>web,authentication_failed,</group>
  </rule>

  <rule id="100138" level="10" frequency="10" timeframe="120">
    <if_matched_sid>100137</if_matched_sid>
    <same_field>ClientHost</same_field>
    <description>Traefik: Django admin brute force, 10 failed logins in 120 s from $(ClientHost)</description>
    <mitre><id>T1110</id></mitre>
    <group>web,authentication_failures,</group>
  </rule>

  <!-- R14: built-in rules 651 and 652 (firewall-drop block and unblock) with
       the blocked IP and the rule that triggered the block in the message.
       Same conditions and groups as in 0015-ossec_rules.xml; only the
       description changes. Checked with wazuh-logtest 4.14.5. -->
  <rule id="651" level="3" overwrite="yes">
    <if_sid>650</if_sid>
    <field name="parameters.program">firewall-drop</field>
    <field name="command">add</field>
    <description>Host Blocked by firewall-drop Active Response: $(parameters.alert.data.srcip) (rule $(parameters.alert.rule.id))</description>
    <group>active_response,pci_dss_11.4,gpg13_4.13,gdpr_IV_35.7.d,nist_800_53_SI.4,tsc_CC6.1,tsc_CC6.8,tsc_CC7.2,tsc_CC7.3,tsc_CC7.4,</group>
  </rule>

  <rule id="652" level="3" overwrite="yes">
    <if_sid>650</if_sid>
    <field name="parameters.program">firewall-drop</field>
    <field name="command">delete</field>
    <description>Host Unblocked by firewall-drop Active Response: $(parameters.alert.data.srcip) (rule $(parameters.alert.rule.id))</description>
    <group>active_response,pci_dss_11.4,gpg13_4.13,gdpr_IV_35.7.d,nist_800_53_SI.4,tsc_CC6.1,tsc_CC6.8,tsc_CC7.2,tsc_CC7.3,tsc_CC7.4,</group>
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
# Load project-specific decoders
# ---------------------------------------------------------------------------
log "Uploading local_decoder.xml ..."
LOCAL_DECODER=$(cat <<'XML'
<!-- simovilab: local decoders.
     Traefik access log (JSON, one line per request). Two sibling decoders (same name and
     parent): a child of json replaces the fields of its parent, so the first sibling extracts
     every field of the JSON again (ClientHost, DownstreamStatus, RequestPath...) and the second
     copies ClientHost into srcip, the field that firewall-drop uses to block the client.
     Checked with wazuh-logtest 4.14.5. -->
<decoder name="simovilab-traefik">
  <parent>json</parent>
  <prematch>"entryPointName":</prematch>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>

<decoder name="simovilab-traefik">
  <parent>json</parent>
  <regex type="pcre2">"ClientHost":"([^"]+)"</regex>
  <order>srcip</order>
</decoder>
XML
)
printf '%s\n' "$LOCAL_DECODER" > /tmp/local_decoder.xml
r=$(curl -s $CURL_TLS -X PUT "${API}/decoders/files/local_decoder.xml?overwrite=true" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary @/tmp/local_decoder.xml)

check "$r" "local_decoder.xml"

# ---------------------------------------------------------------------------
# Validate the configuration before restarting the manager
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
# Renew the token and restart the manager
# ---------------------------------------------------------------------------
# Reauthenticate before restarting to avoid using an expired JWT.
# ---------------------------------------------------------------------------
authenticate
log "Restarting the manager ..."
r=$(api PUT "/manager/restart")
check "$r" "manager restart"

sleep 10
wait_for_api
log "API is available after the restart."

# ---------------------------------------------------------------------------
# Display the group summary and enrollment instructions
# ---------------------------------------------------------------------------

log "Existing groups:"
api GET "/groups" | jq -r '.data.affected_items[] | "  - \(.name) (agents: \(.count))"'

log "Done. The manager is ready to accept registrations; agents can enroll in:"
log "  srv-databus -> group 'databus'   srv-infobus -> group 'infobus'   srv-gestion -> group 'monitoring'"
exit 0