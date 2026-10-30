| Variable | Dónde se define | Para qué |
|---|---|---|
| `DATABUS_PATH`, `INFOBUS_PATH`, `WAZUH_PATH`, `ZABBIX_PATH` | `.env` de **R4** | `wazuh-manager-conf.sh` construye con ellas el `agent.conf` de cada grupo |
| `PROJECT_PATH` | `.env` del **host del agente** (R2 o R3) | El bind mount de solo lectura del compose del agente |
| `REMOTE_AGENT_GROUP` | `.env` del **host del agente** | Qué `agent.conf` le empuja el manager |

`PROJECT_PATH` y `REMOTE_AGENT_GROUP` tienen que concordar:

| | R3 | R2 |
|---|---|---|
| `PROJECT_PATH` | `/home/databus` | `/home/infobus` |
| `REMOTE_AGENT_GROUP` | `databus` | `infobus` |

Y `PROJECT_PATH` del host tiene que ser igual a `DATABUS_PATH` o
`INFOBUS_PATH` del `.env` de R4, según el servidor: el bind mount lo
define el host, el FIM lo define el manager, y si no coinciden el agente
vigila una ruta que no montó.