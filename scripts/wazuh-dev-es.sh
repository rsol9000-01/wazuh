#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Preparar el entorno de desarrollo y desplegar los servicios de Wazuh
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
# Mostrar la sintaxis, las opciones y las acciones disponibles
# ---------------------------------------------------------------------------
usage() {

  echo ""
  echo -e "⚠️  ${YELLOW}Usage:${NC} $0 [server|agent] [action]"
  echo ""
  echo -e "    ${BLUE}server${NC} ---> Run full Wazuh stack using docker-compose.yml"
  echo -e "    ${BLUE}agent${NC}  ---> Run Wazuh agent using docker-compose-agent.yml"
  echo ""
  echo -e "    ${BLUE}action${NC}  ---> up (default), down, logs, ps, restart"
  echo ""

}

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
# Validar que la contraseña cumpla los requisitos de longitud y caracteres
# ---------------------------------------------------------------------------
validate_password() {
  local password="$1"
  # -------------------------------------------------------------------------
  # Elegir el nombre que se incluirá en los mensajes de error
  # -------------------------------------------------------------------------
  local var_name="${2:-Password}"
  local len=${#password}

  # -------------------------------------------------------------------------
  # Comprobar que la longitud esté entre 8 y 64 caracteres
  # -------------------------------------------------------------------------
  if (( len < 8 || len > 64 )); then
    echo "❌  Error: ${var_name} must be between 8 and 64 characters long (current: ${len})."
    return 1
  fi

  # -------------------------------------------------------------------------
  # Exigir al menos una letra mayúscula
  # -------------------------------------------------------------------------
  if [[ ! "$password" =~ [A-Z] ]]; then
    echo "❌  Error: ${var_name} must contain at least one uppercase letter."
    return 1
  fi

  # -------------------------------------------------------------------------
  # Exigir al menos una letra minúscula
  # -------------------------------------------------------------------------
  if [[ ! "$password" =~ [a-z] ]]; then
    echo "❌  Error: ${var_name} must contain at least one lowercase letter."
    return 1
  fi

  # -------------------------------------------------------------------------
  # Exigir al menos un número
  # -------------------------------------------------------------------------
  if [[ ! "$password" =~ [0-9] ]]; then
    echo "❌  Error: ${var_name} must contain at least one digit."
    return 1
  fi

  # -------------------------------------------------------------------------
  # Exigir al menos uno de los símbolos permitidos
  # -------------------------------------------------------------------------
  if [[ ! "$password" =~ [.*+?\-] ]]; then
    echo "❌  Error: ${var_name} must contain at least one of the following symbols: . * + ? -"
    return 1
  fi

  # -------------------------------------------------------------------------
  # Rechazar los caracteres que no están permitidos
  # -------------------------------------------------------------------------
  if [[ "$password" == *['$|&\']* ]]; then
    echo "❌  Error: Character (\$, |, &, \\) it is not allowed on ${var_name}."
    exit 1
  fi

  return 0
}

clear
print_section "$GREEN" "Wazuh infrastructure stack installation script"
# ---------------------------------------------------------------------------
# Detener la ejecución ante errores, variables sin definir o fallos de tubería
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# Cambiar al directorio raíz del repositorio desde cualquier ubicación
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FLAG_SERVER=false

# ---------------------------------------------------------------------------
# Leer el tipo de despliegue y la acción solicitada
# ---------------------------------------------------------------------------
CHOICE="${1:-}"
ACTION="${2:-up}"

# ---------------------------------------------------------------------------
# Validar la cantidad de argumentos recibidos
# ---------------------------------------------------------------------------
if [[ $# -ne 1 && $# -ne 2 ]]; then
  usage
  exit 1
fi

# ---------------------------------------------------------------------------
# Determinar si se desplegará el agente o la infraestructura del servidor
# ---------------------------------------------------------------------------

if [ "$1" = "agent" ]; then
  echo "🛰️   Deploying Wazuh agent..."
elif [ "$1" = "server" ]; then
  echo "🖥️   Deploying full Wazuh server infrastructure..."
  FLAG_SERVER=true
else
  usage
  exit 1
fi

# ---------------------------------------------------------------------------
# Conservar deshabilitado el menú interactivo de selección del despliegue
# ---------------------------------------------------------------------------

#if [[ -z "$CHOICE" ]]; then
#  echo "Select deployment type:"
#  select opt in "server" "agent" "exit"; do
#    case $opt in
#      server) CHOICE=server; break ;;
#      agent) CHOICE=agent; break ;;
#      exit) printf "Exiting.\n"; exit 0 ;;
#      *) echo "Invalid option" ;;
#    esac
#  done
#fi


#print_section "$CYAN" "Selected: $CHOICE | Action: $ACTION"

AGENT_AUTH_PASSWORD_FILE=$REPO_ROOT/config/wazuh_cluster/authd.pass

# ---------------------------------------------------------------------------
# Seleccionar los archivos de configuración y Compose del despliegue
# ---------------------------------------------------------------------------
CERTS_FILE="generate-indexer-certs.yml"
COMPOSE_FILE="docker-compose.yml"
if [ "$FLAG_SERVER" = "false" ]; then
  COMPOSE_FILE="agent/docker-compose-agent.yml"
fi


INTERNAL_USERS_FILE="$REPO_ROOT/config/wazuh_indexer/internal_users.yml"

# ---------------------------------------------------------------------------
# Ajustar vm.max_map_count cuando se despliegue el servidor
# ---------------------------------------------------------------------------

if [ "$FLAG_SERVER" = "true" ]; then
  CURRENT=$(cat /proc/sys/vm/max_map_count)
  REQUIRED=262144

  echo -e "💾  Current vm.max_map_count: ${GREEN}$CURRENT${NC}"

  if [ "$CURRENT" -lt "$REQUIRED" ]; then
      echo "   - 🔧 Setting vm.max_map_count to $REQUIRED..."
      sysctl -w vm.max_map_count=$REQUIRED
      echo 'vm.max_map_count=262144' >> /etc/sysctl.conf
      sysctl -p
  else
      echo "    - ✅ vm.max_map_count already satisfies the requirement."
  fi
else
  echo "💾  Skipping vm.max_map_count check for agent deployment."
fi  

# ---------------------------------------------------------------------------
# Comprobar e instalar las dependencias necesarias
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Verificar que Docker esté instalado y disponible
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "❌  Error: docker is not installed or not in PATH."
    exit 1
fi
echo -e "✅  Docker ready: ${GREEN}$(docker --version | cut -d' ' -f1-3)${NC}"

# ---------------------------------------------------------------------------
# Obtener el identificador del grupo de Docker
# ---------------------------------------------------------------------------
DOCKER_GID=$(getent group docker | cut -d: -f3 || true)
if [ -z "$DOCKER_GID" ]; then
    echo "❌  Docker group not found."
    exit 1
fi

#export DOCKER_GID
echo -e "🐳  Docker GID: ${GREEN}$DOCKER_GID${NC}"

# ---------------------------------------------------------------------------
# Instalar curl y verificar su disponibilidad en modo servidor
# ---------------------------------------------------------------------------
if [ "$FLAG_SERVER" = "true" ]; then
  if ! command -v curl &> /dev/null; then
    echo "🔧  Installing curl..."
    command -v apt-get &> /dev/null && apt-get update -qq && apt-get install -y -qq curl
  fi
  command -v curl &> /dev/null || { echo "❌  Error: curl is not installed or not in PATH."; exit 1; }
  echo -e "✅  curl ready: ${GREEN}$(curl -V | head -n1 | cut -d' ' -f1-2)${NC}"
fi

# ---------------------------------------------------------------------------
# Crear /var/log/auth.log con rsyslog si el sistema todavía no lo proporciona
# ---------------------------------------------------------------------------
# Sin rsyslog, el agente no recibe los eventos SSH desde journald. Si la
# instalación o el inicio del servicio falla, continuar y mostrar una alerta.
# ---------------------------------------------------------------------------
if [ ! -f /var/log/auth.log ]; then
  if command -v apt-get &> /dev/null; then
    echo "🔧  /var/log/auth.log not found. Installing rsyslog..."
    if apt-get update -qq && apt-get install -y -qq rsyslog; then
      systemctl enable --now rsyslog || echo -e "⚠️  ${YELLOW}rsyslog installed but could not be started.${NC}"
      echo -e "✅  rsyslog ready: sshd events -> ${GREEN}/var/log/auth.log${NC}"
    else
      echo -e "⚠️  ${YELLOW}Could not install rsyslog. SSH events will not reach Wazuh.${NC}"
    fi
  else
    echo -e "⚠️  ${YELLOW}/var/log/auth.log not found and apt-get unavailable. SSH events will not reach Wazuh.${NC}"
  fi
else
  echo -e "✅  /var/log/auth.log present."
fi

#--------------- apache utilities for htpasswd -------------------
#if ! command -v htpasswd &> /dev/null; then
#  echo "🔧  Installing apache2-utils..."
#  command -v apt-get &> /dev/null && apt-get update -qq && apt-get install -y -qq apache2-utils
#fi
#command -v htpasswd &> /dev/null || { echo "❌  Error: htpasswd is not installed or not in PATH."; exit 1; }
#echo "✅  htpasswd ready."


# ---------------------------------------------------------------------------
# Comprobar los archivos requeridos para el despliegue
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Verificar la existencia del archivo de variables de entorno
# ---------------------------------------------------------------------------
if [ ! -f ".env" ]; then
    echo "🚨  Warning: .env file not found."
    if [ -f ".env.example" ]; then
        echo "ℹ️  Copying .env.example -> .env ..."
        cp .env.example .env
        echo "⚠️  Edit .env with your values before continuing."
    fi
    exit 1
fi
echo "✅  The environment variables will be loaded from the .env file."


# ---------------------------------------------------------------------------
# Verificar la existencia del archivo de Docker Compose seleccionado
# ---------------------------------------------------------------------------
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "❌  Error: $COMPOSE_FILE not found."
    exit 1
fi
echo -e "✅  Docker Compose file found: ${GREEN}$COMPOSE_FILE${NC}"

# ---------------------------------------------------------------------------
# Crear y verificar el archivo de usuarios internos en modo servidor
# ---------------------------------------------------------------------------
if [ "$FLAG_SERVER" = "true" ]; then
  [ -f "$INTERNAL_USERS_FILE" ] || cp "${INTERNAL_USERS_FILE}.template" "$INTERNAL_USERS_FILE"
  if [ ! -f "$INTERNAL_USERS_FILE" ]; then
      echo "❌  Error: $INTERNAL_USERS_FILE not found."
      exit 1
  fi
  echo -e "✅  Internal users file found: ${GREEN}$INTERNAL_USERS_FILE${NC}"
fi

# ---------------------------------------------------------------------------
# Verificar el archivo de generación de certificados en modo servidor
# ---------------------------------------------------------------------------

if [ "$FLAG_SERVER" = "true" ]; then
  if [ ! -f "$CERTS_FILE" ]; then
    echo "❌  Error: $CERTS_FILE not found."
    exit 1
  fi
  echo -e "✅  Certs file found: ${GREEN}$CERTS_FILE${NC}"
fi
# ---------------------------------------------------------------------------
# Verificar y habilitar el script posterior a la instalación del agente
# ---------------------------------------------------------------------------

CONFIG_AGENT_SCRIPT=$(grep '^CONFIG_AGENT_SCRIPT[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)

if [ -z "$CONFIG_AGENT_SCRIPT" ]; then
    echo "❌ Error: CONFIG_AGENT_SCRIPT is not set in .env"
    exit 1
fi
   
if [ ! -f "$CONFIG_AGENT_SCRIPT" ]; then
  echo "❌  Error: $CONFIG_AGENT_SCRIPT not found."
  exit 1
fi
echo -e "✅  Post-install script found: ${GREEN}$REPO_ROOT/$CONFIG_AGENT_SCRIPT${NC}"
chmod +x $CONFIG_AGENT_SCRIPT

# ---------------------------------------------------------------------------
# Preparar y verificar el archivo de conexión a la API del dashboard
# ---------------------------------------------------------------------------
if [ "$FLAG_SERVER" = "true" ]; then
  API_DATA="$REPO_ROOT/config/wazuh_dashboard/wazuh.yml"
  [ -f "$API_DATA" ] || cp "${API_DATA}.template" "$API_DATA"
  if [ ! -f "$API_DATA" ]; then
    echo "❌  Error: $API_DATA not found."
    exit 1
  fi
    echo -e "✅  API data file found: ${GREEN}$API_DATA${NC}"
fi

# ---------------------------------------------------------------------------
# Generar el archivo de autenticación del agente desde la variable de .env
# ---------------------------------------------------------------------------
 
#if [ ! -f "$AGENT_AUTH_PASSWORD_FILE" ]; then
#  echo "❌  Error: $AGENT_AUTH_PASSWORD_FILE not found."
#  exit 1
#fi
#  echo -e "✅  Auth password file found."


# ---------------------------------------------------------------------------
# Obtener y exportar el nombre del agente local
# ---------------------------------------------------------------------------

LOCAL_AGENT_HOSTNAME=$(grep '^LOCAL_AGENT_HOSTNAME[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)

if [ -z "$LOCAL_AGENT_HOSTNAME" ]; then
    echo "❌ Error: LOCAL_AGENT_HOSTNAME is not set in .env"
    exit 1
fi

if [[ "$LOCAL_AGENT_HOSTNAME" == "localhost" ]]; then
    # -----------------------------------------------------------------------
    # Reemplazar localhost por el nombre completo del equipo
    # -----------------------------------------------------------------------
    LOCAL_AGENT_HOSTNAME=$(hostname -f || true)
fi

echo -e "📝  Agent hostname to use: ${YELLOW}$LOCAL_AGENT_HOSTNAME${NC}"
export LOCAL_AGENT_HOSTNAME

# ---------------------------------------------------------------------------
# Configurar la contraseña de la API en modo servidor
# ---------------------------------------------------------------------------

if [ "$FLAG_SERVER" = "true" ]; then
  API_NEW_PASSWORD=$(grep '^API_PASSWORD[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)
  if [ -z "$API_NEW_PASSWORD" ]; then
    echo "❌ Error: API_PASSWORD is not set in .env"
    exit 1
  fi
  # -------------------------------------------------------------------------
  # Validar la contraseña antes de actualizar la configuración del dashboard
  # -------------------------------------------------------------------------
  if ! validate_password "$API_NEW_PASSWORD" "API_PASSWORD"; then
    exit 1
  fi

  sed -i "s|^\([[:space:]]*password:[[:space:]]*\).*|\1$API_NEW_PASSWORD|" "$API_DATA"

  echo -e "✅  API data file updated with credentials defined on .env file"
fi


# ---------------------------------------------------------------------------
# Crear o actualizar el usuario administrador definido en .env
# ---------------------------------------------------------------------------
if [ "$FLAG_SERVER" = "true" ]; then
  MY_USERNAME=$(grep '^MY_USERNAME[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)
  if [ -z "$MY_USERNAME" ]; then
      echo "❌ Error: MY_USERNAME is not set in .env"
      exit 1
  fi
  MY_PASSWORD=$(grep '^MY_PASSWORD[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)
  if [ -z "$MY_PASSWORD" ]; then
      echo "❌ Error: MY_PASSWORD is not set in .env"
      exit 1
  fi
  if [[ "$MY_PASSWORD" == *['$|&\']* ]]; then
      echo "❌  Error: Character (\$, |, &, \\) it is not allowed on MY_PASSWORD."
      exit 1
  fi

  MY_HASH=$(docker run --rm wazuh/wazuh-indexer:4.14.5 /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "$MY_PASSWORD")

  if grep -q "^[[:space:]]*${MY_USERNAME}:" "$INTERNAL_USERS_FILE"; then
      #sed -i "/^[[:space:]]*${MY_USERNAME}:/,/^[[:space:]]*[^[:space:]]/ s/^[[:space:]]*hash:.*/  hash: \"${MY_HASH}\"/" "$INTERNAL_USERS_FILE"
      sed -i "/^[[:space:]]*${MY_USERNAME}:/,/^[[:space:]]*[^[:space:]]/ s#^[[:space:]]*hash:.*#  hash: \"${MY_HASH}\"#" "$INTERNAL_USERS_FILE"
      echo -e "✅  Password updated for user ${YELLOW}$MY_USERNAME${NC}"
  else
      cat >> "$INTERNAL_USERS_FILE" <<EOF

${MY_USERNAME}:
  hash: "${MY_HASH}"
  reserved: false
  backend_roles:
    - "admin"
  description: "Usuario administrador nuevo"
EOF

    echo "✅  New user created with credentials defined on .env: $MY_USERNAME:MY_PASSWORD"
  fi
fi
# ---------------------------------------------------------------------------
# Actualizar en .env el identificador del grupo de Docker
# ---------------------------------------------------------------------------
sed -i "s|^\([[:space:]]*DOCKER_GID=[[:space:]]*\).*|\1$DOCKER_GID|" .env

# ---------------------------------------------------------------------------
# Actualizar la contraseña de kibanaserver en modo servidor
# ---------------------------------------------------------------------------

if [ "$FLAG_SERVER" = "true" ]; then
  KIBANA_PASSWORD=$(grep '^DASHBOARD_PASSWORD[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)
  if [ -z "$KIBANA_PASSWORD" ]; then
      echo "❌ Error: DASHBOARD_PASSWORD is not set in .env"
      exit 1
  fi

  if [[ "$KIBANA_PASSWORD" != kibanaserver ]]; then
    # -----------------------------------------------------------------------
    # Validar la contraseña antes de calcular y guardar su hash
    # -----------------------------------------------------------------------
    if ! validate_password "$KIBANA_PASSWORD" "DASHBOARD_PASSWORD"; then
      exit 1
    fi
    KIBANA_HASH=$(docker run --rm wazuh/wazuh-indexer:4.14.5 /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "$KIBANA_PASSWORD")
    if grep -q "^[[:space:]]*kibanaserver:" "$INTERNAL_USERS_FILE"; then
      sed -i "/^[[:space:]]*kibanaserver:/,/^[[:space:]]*[^[:space:]]/ s#^[[:space:]]*hash:.*#  hash: \"${KIBANA_HASH}\"#" "$INTERNAL_USERS_FILE"
      echo -e "✅  Password updated for user ${YELLOW}kibanaserver${NC}"
    else
      echo -e "❌ ERROR: Kibanaserver user not found."
      exit 1
    fi
  else
    echo -e "⚠️  Warning: the Kibana/dashboard password is still the default '${YELLOW}kibanaserver${NC}'. Please change it in .env."
  fi
fi
#exit 1

# ---------------------------------------------------------------------------
# Validar y guardar la contraseña de autenticación del agente
# ---------------------------------------------------------------------------
AGENT_AUTH_PASSWORD=$(grep '^AGENT_AUTH_PASSWORD[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)
if [ -z "$AGENT_AUTH_PASSWORD" ]; then
    echo "❌ Error: AGENT_AUTH_PASSWORD is not set in .env"
    exit 1
fi
# ---------------------------------------------------------------------------
# Validar la contraseña antes de guardarla en el archivo de autenticación
# ---------------------------------------------------------------------------
if ! validate_password "$AGENT_AUTH_PASSWORD" "AGENT_AUTH_PASSWORD"; then
    exit 1
fi

echo -n "$AGENT_AUTH_PASSWORD" > $AGENT_AUTH_PASSWORD_FILE

# ---------------------------------------------------------------------------
# Reservar para configuración manual la creación del grupo y permisos del archivo
# ---------------------------------------------------------------------------
#groupadd -r wazuh 2>/dev/null || true
#chmod 640 $AGENT_AUTH_PASSWORD_FILE
#chown root:wazuh $AGENT_AUTH_PASSWORD_FILE
echo -e "✅  Agent authentication password saved to: ${GREEN}$AGENT_AUTH_PASSWORD_FILE${NC}"

# ---------------------------------------------------------------------------
# Generar certificados autofirmados en modo servidor
# ---------------------------------------------------------------------------

if [ "$FLAG_SERVER" = "true" ]; then
  echo "🔐  Generating self-signed certificates..."
  docker compose -f generate-indexer-certs.yml run --rm generator
  echo "✅  Certificates generated at ./config/wazuh_indexer_ssl_certs."
fi

# ---------------------------------------------------------------------------
# Ejecutar la acción solicitada mediante Docker Compose
# ---------------------------------------------------------------------------

DC=(docker compose -f "$COMPOSE_FILE" --env-file "$REPO_ROOT/.env")

case "$ACTION" in
  up)
    echo -e "🚀  ${GREEN}Starting Docker Compose deployment...${NC}"
    "${DC[@]}" up -d
    ;;
  down)
    echo -e "🛑  ${YELLOW}Stopping stack...${NC}"
    "${DC[@]}" down
    ;;
  restart)
    echo -e "🔄  ${CYAN}Restarting stack...${NC}"
    "${DC[@]}" restart
    ;;
  logs)
    "${DC[@]}" logs -f
    ;;
  ps)
    "${DC[@]}" ps
    ;;
  *)
    echo -e "❌  ${RED}Unknown action: ${ACTION}${NC}"
    usage
    exit 1
    ;;
esac
#docker compose logs -f wazuh-init
