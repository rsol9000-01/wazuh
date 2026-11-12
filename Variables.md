# Variables de Wazuh

Este documento ordena las variables más relevantes del flujo de despliegue y configuración por capas: primero las que se leen o entregan al script, luego las de estado/runtime, luego las internas de funciones y finalmente las de validación o bucles.

| Capa | Variable | Qué hace | Nueva nomenclatura | Dónde se define / para qué se usa |
| --- | --- | --- | --- | --- |
| 1. Expuesta / entrada | `WAZUH_MANAGER_SERVER` | Dirección del manager para enrolamiento del agente. |  | Definida en el entorno o en `.env`. En `wazuh-agent-conf.sh` se usa para reemplazar el `<address>` del bloque `<server>` dentro del `ossec.conf` del agente, indicando a qué manager debe conectarse. |
| 1. Expuesta / entrada | `WAZUH_AGENT_GROUP` | Grupo de enrolamiento del agente. |  | Definida en `.env` y leída en `wazuh-agent-conf.sh`. Se usa para escribir `<groups>...` en la configuración del agente, para que el agente se asocie a un grupo de enrolamiento del manager. |
| 1. Expuesta / entrada | `WAZUH_AGENT_NAME` | Nombre del agente durante el enrolamiento. |  | Definida en `.env` o en el entorno. El script la usa para poner `<agent_name>` dentro del bloque `<enrollment>` de `ossec.conf`, porque en `network_mode: host` el nombre del contenedor no se puede confiar. |
| 1. Expuesta / entrada | `API` | URL base de la API del manager. |  | Definida en `wazuh-manager-conf.sh` como `API="${WAZUH_API_URL:-https://wazuh.manager:55000}"`. Se usa en todas las llamadas HTTP a la API del manager para configurar grupos, rules, agentes y restarts. |
| 1. Expuesta / entrada | `USER` / `PASS` | Credenciales de la API Wazuh. |  | Definidas a partir de `WAZUH_API_USER` y `WAZUH_API_PASSWORD` en `.env`. Se usan en la función `api()` de `wazuh-manager-conf.sh` para autenticar cada llamada a la API del manager. |
| 1. Expuesta / entrada | `INSECURE` | Si la API acepta certificados TLS no válidos. |  | Definida en `.env` como `WAZUH_API_INSECURE` y usada por `curl` para desactivar la validación TLS en entornos con certificados autofirmados. |
| 1. Expuesta / entrada | `DATABUS_PATH` / `INFOBUS_PATH` / `WAZUH_PATH` / `ZABBIX_PATH` | Paths del entorno del proyecto para cada servicio/rol. |  | Definidas en `.env` y usadas en `wazuh-manager-conf.sh` para apuntar a los directorios donde viven los repositorios o archivos de configuración. |
| 1. Expuesta / entrada | `AGENT_GROUPS` | Grupos de agentes definidos para el manager. |  | Definida en el script (`AGENT_GROUPS="databus infobus monitoring"`). Sirve para crear o mantener los grupos de configuración del manager y asociar la política de cada rol. |
| 1. Expuesta / entrada | `LOCAL_AGENT_HOSTNAME` | Hostname del agente local. |  | Definida en `.env` como `LOCAL_AGENT_HOSTNAME`, se usa para asegurar el nombre del agente local del stack Wazuh y para exportarlo al entorno del contenedor. |
| 1. Expuesta / entrada | `MY_USERNAME` / `MY_PASSWORD` | Usuario administrador del dashboard. |  | Definidas en `.env` y usadas cuando el script crea o actualiza el usuario administrativo en `internal_users.yml` para el dashboard de Wazuh. |
| 1. Expuesta / entrada | `API_PASSWORD` | Contraseña de acceso a la API del dashboard. |  | Definida en `.env`. El script la usa para reemplazar la contraseña en `config/wazuh_dashboard/wazuh.yml` para que el dashboard se conecte correctamente. |
| 1. Expuesta / entrada | `DASHBOARD_PASSWORD` | Contraseña del usuario `kibanaserver`. |  | Definida en `.env`. Se usa para calcular el hash del usuario `kibanaserver` y actualizarlo en `internal_users.yml`, permitiendo su login en el dashboard. |
| 1. Expuesta / entrada | `AGENT_AUTH_PASSWORD` | Contraseña para enrolar al agente. |  | Definida en `.env`. En `wazuh-dev.sh` se usa para guardar el valor en `config/wazuh_cluster/authd.pass`, que es el archivo que usa el manager para validar el enrolamiento del agente. |
| 1. Expuesta / entrada | `CONFIG_AGENT_SCRIPT` | Script post-install del agente. |  | Definido en `.env` y usado en `wazuh-dev.sh` para asegurar que existe el script de configuración del agente y ejecutarlo al arrancar el contenedor. |
| 1. Expuesta / entrada | `CHOICE` / `ACTION` | Modo del despliegue y acción a ejecutar. |  | Definidas en el script. `CHOICE` decide si es `server` o `agent`; `ACTION` decide si se ejecuta `up`, `down`, `restart` o `logs`. |
| 2. Estado de runtime | `REPO_ROOT` | Ruta raíz del repositorio. |  | Se calcula en `wazuh-dev.sh` con `dirname` y `pwd`, y se usa para localizar `.env`, `docker-compose.yml`, `internal_users.yml`, certificados y scripts del despliegue. |
| 2. Estado de runtime | `FLAG_SERVER` | Indica si el flujo actual es de servidor. |  | Se define según el primer argumento del script. Cambia el comportamiento del despliegue, por ejemplo si se valida `vm.max_map_count`, se crean certificados o se usa `/var/log/auth.log`. |
| 2. Estado de runtime | `AGENT_AUTH_PASSWORD_FILE` | Ruta donde se escribe `authd.pass`. |  | Se define en `wazuh-dev.sh` como `$REPO_ROOT/config/wazuh_cluster/authd.pass`. El script la usa para guardar la contraseña del agente para que el manager la lea al enrolarse. |
| 2. Estado de runtime | `CERTS_FILE` / `COMPOSE_FILE` / `INTERNAL_USERS_FILE` | Archivos relevantes del despliegue según el modo. |  | Se resuelven en runtime según `FLAG_SERVER`. Se usan para validar que existan los archivos esenciales y para orquestar `docker compose` y los ajustes del manager. |
| 2. Estado de runtime | `DOCKER_GID` | GID del grupo `docker` del host. |  | Se obtiene con `getent group docker` y se usa para que el contenedor acceda al socket de Docker sin errores. También se guarda de nuevo en `.env`. |
| 2. Estado de runtime | `DC` | Array que monta la invocación de `docker compose` con `--env-file`. |  | Se arma en `wazuh-dev.sh` y se reutiliza en `up`, `down`, `restart` y `logs` para ejecutar el mismo comando de manera consistente. |
| 2. Estado de runtime | `API_DATA` | Ruta del archivo de configuración del dashboard Wazuh (`wazuh.yml`). |  | Se define según `FLAG_SERVER` y se usa para actualizar la contraseña de conexión de la API del dashboard y de la UI. |
| 2. Estado de runtime | `CURRENT` / `REQUIRED` | Valor actual y mínimo de `vm.max_map_count`. |  | Se calculan en modo servidor para comprobar si el host cumple la condición de kernel requerida por Elasticsearch/Opensearch. Si no, se ajusta con `sysctl`. |
| 2. Estado de runtime | `MY_HASH` / `KIBANA_HASH` | Hashes calculados para las contraseñas de los usuarios del dashboard. |  | Se generan con `hash.sh` del índice de OpenSearch y se insertan en `internal_users.yml` para que el usuario administrador y `kibanaserver` puedan autenticarse. |
| 2. Estado de runtime | `LOCAL_RULES` | XML con reglas locales del manager. |  | Se define en `wazuh-manager-conf.sh` y se usa para subir al manager el archivo local de reglas con `PUT /rules/files/local_rules.xml?overwrite=true`. |
| 2. Estado de runtime | `AGENT_CONF_DATABUS` / `AGENT_CONF_INFOBUS` / `AGENT_CONF_MONITORING` | XML de configuración de cada grupo de agentes. |  | Se arman como heredocs y se publican con `api PUT` para inyectar la configuración correcta en cada grupo (`databus`, `infobus`, `monitoring`). |
| 2. Estado de runtime | `status` / `i` | Estado y contador del bucle de control. |  | Variables locales en un `while`/`for` del script. Se usan para escribir el estado del proceso de reinicio del manager o para iterar algún estado de comprobación. |
| 3. Interna de función | `MANAGER` | Dirección del manager calculada desde el argumento o el entorno. |  | Variable local de `wazuh-agent-conf.sh`. Se usa para decidir a qué dirección apuntar el agente, y se define como `WAZUH_MANAGER_SERVER` si no viene como argumento del script. |
| 3. Interna de función | `SCRIPT_POST_INSTALL` | Ruta al script de post-install del servidor. |  | Se define en `wazuh-dev.sh` leyendo `.env`. Se usa para validar que existe el script que deja preparado el entorno de servidor antes de levantar contenedores. |
| 3. Interna de función | `USER_SCRIPTS_DIR` | Ruta al directorio de scripts auxiliares del repo. |  | Se define en `zabbix-dev.sh` y se usa para crear el directorio, aplicar permisos y asegurar que los scripts de usuario que ejecuta Docker o los agentes quedan accesibles. |
| 3. Interna de función | `AGENT_SUDOERS_FILE` / `AGENT_SUDOERS_FILE_ROUTE` | Archivo `sudoers` para scripts del agente. |  | Se leen desde `.env` y se usan para crear/normalizar el archivo del agente que permite ejecutar scripts sin password como `zabbix`. |
| 3. Interna de función | `DOCKERFILE` | Ruta del Dockerfile del agente Zabbix. |  | Aunque no es una variable de Wazuh, aparece en la lógica de despliegue del repo Zabbix. Se usa para construir la imagen del agente con el Dockerfile adecuado. |
| 3. Interna de función | `ZBX_AGENT_CONFIG_FILE` / `ZBX_AGENT_CONFIG_FILE_ROUTE` | Archivo de configuración del agente Zabbix. |  | Variables de entorno del proyecto Zabbix; en Wazuh no forman parte del flujo principal pero aparecen en scripts compartidos de configuración o despliegue. |
| 3. Interna de función | `AGENT_PLUGINS_FILE_ROUTE` | Ruta del archivo de plugins para el agente Zabbix. |  | Se crea a partir del ejemplo si no existe y se usa para definir la configuración de plugins del agente Zabbix. |
| 3. Interna de función | `MATCHES` | Resultado del `grep` de `AGENT_PARAMS_*` en `.env`. |  | Se usa en `zabbix-dev.sh` para detectar líneas tipo `AGENT_PARAMS_X=ITEMKEY:SCRIPTNAME` y convertirlas en `UserParameter=...` dentro de la config del agente. |
| 3. Interna de función | `VALUE`, `ITEMKEY`, `SCRIPTNAME`, `NEW_LINE`, `EXISTS` | Datos del procesamiento de `UserParameter`. |  | Variables locales del loop sobre `.env`; sirven para parsear cada línea y evitar duplicados en el archivo de configuración del agente. |
| 3. Interna de función | `PSK_KDF_SALT` / `PSK_VALUE` | Salt y PSK derivada para Zabbix. |  | Estas variables aparecen dentro del repo de Zabbix, no del flujo Wazuh principal. Sirven para generar la PSK determinista a partir de una semilla. |
| 4. Validación / bucles | `RED`, `GREEN`, `YELLOW`, `BLUE`, `CYAN`, `GRAY`, `NC` | Colores para mensajes del terminal. |  | Definidas en cada script. Solo afectan la legibilidad del log; no cambian la lógica del despliegue ni la configuración. |
| 4. Validación / bucles | `password`, `var_name`, `len` | Variables de validación de contraseñas. |  | Se usan dentro de `validate_password()`. Sirven para verificar longitud, presencia de mayúsculas/minúsculas/números/símbolos, y para bloquear caracteres no permitidos. |
| 4. Validación / bucles | `r` | Resultado de llamadas API o curl. |  | Variable reutilizada por la función `api()` de `wazuh-manager-conf.sh` y por otras partes del script. Se usa para capturar la respuesta HTTP y luego validarla. |
| 4. Validación / bucles | `INIT_ID` / `INIT_RC` | ID del contenedor `init` y código de salida. |  | Aunque pertenecen al despliegue de Zabbix, se usan para validar que el contenedor de inicialización terminó sin errores durante la puesta en marcha. |

## Observación de naming

La convención recomendada para renombrar sería:

- usar prefijos por dominio: `wazuh_`, `env_`, `cfg_`, `api_`, `agent_`, `run_`
- evitar nombres cortos ambiguos como `API`, `PASS`, `ID`, `STATUS`, `FLAG`
- separar claramente variables de entrada, de entorno y de control

Ejemplos:

- `API` -> `wazuh_api_url`
- `USER` -> `wazuh_api_user`
- `PASS` -> `wazuh_api_password`
- `LOCAL_AGENT_HOSTNAME` -> `wazuh_local_agent_hostname`
- `AGENT_AUTH_PASSWORD` -> `wazuh_agent_auth_password`
- `DOCKER_GID` -> `docker_gid`
- `FLAG_SERVER` -> `run_server_mode`

## Nota

La lista prioriza las variables que realmente impactan el comportamiento del despliegue y la configuración. Las que son solo de logs, colores o utilidades de shell se dejan en la capa final como secundarias.
