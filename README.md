Agente de Wazuh

Ejecutar el agente de Wazuh en un contenedor Docker ofrece una opción ligera para integraciones y para recopilar registros mediante syslog, sin necesidad de instalar el agente directamente en un host. Sin embargo, al implementarse de esta manera, el agente en contenedor no puede acceder ni monitorizar directamente el sistema host

# **Wazuh Monitoring Stack – Docker Compose**

![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?style=for-the-badge&logo=docker)
![Zabbix](https://img.shields.io/badge/Wazuh-4.14-D50000?style=for-the-badge)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17.6-336791?style=for-the-badge&logo=postgresql)

Stack completo y modular para desplegar **Wazuh 4.14** en entornos de producción utilizando **Docker Compose**.
Incluye base de datos, servidor, interfaz web.

---

# 📦 **Arquitectura del Stack**

| Componente          | Versión | Descripción                             |
| ------------------- | ------- | --------------------------------------- |
| **Wazuh Indexer**   | 4.14.1  | Base de datos de Wazuh                  |
| **Wazuh Manager**   | 4.14.1  | Servidor principal                      |
| **Wazuh Dashborad** | 4.14.1  | Interfaz gráfica                        |
| **Wazuh Agent**     | 4.14.1  | Agente avanzado para monitoreo del host |

---
<img src="./diagramas/wazuh-docker.png" alt="Diagrama Wazuh Docker" width=80%>

---


# 🔌 **Mapa de Puertos**

| Puerto    | Protocolo | Uso                                 |
| --------- | --------- | ----------------------------------- |
| **1514**  | TCP       | Agents ↔ Server                     |
| **1515**  | TCP       | Registro y Autenticación de Agentes |
| **514**   | UDP       | Syslog                              |
| **55000** | TCP       | Wazuh server API                    |
| **9200**  | TCP       | Wazuh indexer API                   |
| **7443**   | TCP       | Interfaz Web (HTTP)                 |

---

# 💾 **Volúmenes Persistentes**

| Volumen                   | Contenedor      | Uso                          |
| ------------------------- | --------------- | ---------------------------- |
| `wazuh_api_configuration` | Wazuh Manager   | Base de datos Wazuh          |
| `wazuh_etc`               | Wazuh Manager   | Configuración y runtime      |
| `wazuh_logs`              | Wazuh Manager   | Almacenamiento de traps SNMP |
| `wazuh_queue`             | Wazuh Manager   | Configuración del frontend   |
| `wazuh_var_multigroups`   | Wazuh Manager   | Configuración del frontend   |
| `wazuh_integrations`      | Wazuh Manager   | Certificados SSL/TLS         |
| `wazuh_active_response`   | Wazuh Manager   | Certificados SSL/TLS         |
| `wazuh_agentless`         | Wazuh Manager   | Certificados SSL/TLS         |
| `wazuh_wodles`            | Wazuh Manager   | Certificados SSL/TLS         |
| `filebeat_etc`            | Wazuh Manager   | Certificados SSL/TLS         |
| `filebeat_var`            | Wazuh Manager   | Certificados SSL/TLS         |
| `wazuh-indexer-data`      | Wazuh Indexer   | Base de datos Wazuh          |
| `wazuh-dashboard-config`  | Wazuh Dashboard | Certificados SSL/TLS         |
| `wazuh-dashboard-custom`  | Wazuh Dashboard | Certificados SSL/TLS         |

Todos los volúmenes persisten automáticamente entre reinicios.

---

# 🚀 **Implementación Rápida**

### **1. Prerrequisitos**

- **Docker Engine 20.10+**
- **Docker Compose 2.0+**
- **Puertos 1514/1515/514/55000/9200/7443 disponibles**

---

## **2. Descargar o Clonar el repositorio**

```bash
sudo git clone https://github.com/rsol9000/wazuh-docker.git
cd zabbix-stack
````
---
## **3. Generar los certificados auto-firmados para la comunicación entre contenedores de los 3 componentes de Wazuh**

```bash
sudo docker compose -f generate-indexer-certs.yml run --rm generator
````
- **Los certificados se generan en ./config/wazuh_indexer_ssl_certs/**
---
## **4. Configurar variables de entorno**

```bash
sudo nano .env
```

### **Variables críticas**

```env
NO HAY
```

### **Variables opcionales**

```env
NGINX_IMAGE=nginx:1.29.3-alpine
PROJECT_ROOT=.
NETWORK=net_00
SUBNET=10.60.60.0/24
GATEWAY=10.60.60.1
INDEXER_USERNAME=admin
INDEXER_PASSWORD=SecretPassword
API_USERNAME=wazuh-wui
API_PASSWORD=MyS3cr37P450r.*-
DASHBOARD_USERNAME=kibanaserver
DASHBOARD_PASSWORD=kibanaserver
CERTS_VOLUMEN=zabbix-stack00_zabbix_certificados
```
---

# ▶️ **Despliegue**

```bash
sudo docker-compose up -d
```
---

Comprobar estado:

```bash
sudo docker-compose ps
```

Logs del servidor:

```bash
sudo docker-compose logs -f wazuh.manager
```

---

# 🌐 **Acceso a la Interfaz Web**

| Protocolo | URL                          |
| --------- | ---------------------------- |
| **HTTPS** | `https://<IP-SERVIDOR>:6443` |

---

# 🔐 **Habilitar HTTPS**

```bash
Pendiente
```

Requiere certificados válidos (Let’s Encrypt, ACME u otros).

---

# 🖥️ **Agentes Zabbix**

El stack incluye **Zabbix Agent2 local**.
Para agentes remotos:

```bash
ZabbixServer=<SERVER_IP>
ZabbixServerActive=<SERVER_IP>
```

Ideal para servidores Linux, contenedores o equipos remotos.

---

# 📡 **Monitoreo por SNMP Traps**

El receptor escucha en **UDP 162**.

Ejemplo para routers/switches:

```
snmp-server host <ZABBIX_SERVER_IP> traps version 2c public
```

---

# 🛠️ **Comandos Útiles de Administración**

```bash
# Estado del stack
docker-compose ps

# Logs globales
docker-compose logs -f

# Backup de la base de datos
docker-compose exec postgres pg_dump -U $POSTGRES_USER zabbix > backup.sql

# Reinicio de servicios
docker-compose restart zabbix-server

# Bajar el stack completo
docker-compose down
```

# ⚙️ **Cambios en la configuración del manager (`wazuh_manager.conf`)**

`config/wazuh_cluster/wazuh_manager.conf` se monta en `/wazuh-config-mount/etc/ossec.conf`.
Al arrancar el contenedor, el script de la imagen (`/etc/cont-init.d/0-wazuh-init`)
lo copia a `/var/ossec/etc/ossec.conf`, que es el archivo que usa el manager.

### ⚠️ Limitación conocida de la imagen `wazuh/wazuh-manager:4.14.5`

| Arranque | Resultado |
|---|---|
| **Primero** (despliegue nuevo) | Copia `wazuh_manager.conf` correctamente |
| **Siguientes** (restart, recreate, reinicio del host) | **No lo copia**: el manager sigue con la configuración que ya tenía |

**Causa:** el script borra `/var/ossec/data_tmp` al terminar el primer arranque.
En los siguientes, el volumen `wazuh_var_multigroups` sigue vacío (no hay agentes
con varios grupos), la copia desde `data_tmp` falla y el script sale antes de copiar
la configuración. En los logs aparece:

```text
Error executing command: 'cp -ar /var/ossec/data_tmp/permanent/var/ossec/var/multigroups/. /var/ossec/var/multigroups'.
[cont-init.d] 0-wazuh-init: exited 1.
```

El repositorio oficial `wazuh-docker` lo corrige en la rama 5.x; ninguna versión 4.14.x
publicada trae la corrección.

### ✅ Cuándo NO hay que hacer nada

- Despliegue nuevo: toma `wazuh_manager.conf` del repositorio.
- Reinicios sin cambios en `wazuh_manager.conf`: la configuración persiste en el volumen `wazuh_etc`.
- Cambios en grupos, `agent.conf` o `local_rules.xml`: los aplica `wazuh-init` por la API
  (`docker compose up -d wazuh-init`).

### 🔧 Procedimiento al modificar `wazuh_manager.conf` en un despliegue existente

```bash
cd /home/wazuh

# 1. Ver qué cambia respecto a la configuración en uso
docker cp wazuh.manager:/var/ossec/etc/ossec.conf /tmp/ossec.en-uso.conf
diff /tmp/ossec.en-uso.conf config/wazuh_cluster/wazuh_manager.conf

# 2. Validar el archivo nuevo (no modifica nada)
docker exec wazuh.manager /var/ossec/bin/wazuh-analysisd -t -c /wazuh-config-mount/etc/ossec.conf && echo "config OK"

# 3. Solo si dio "config OK": respaldar y aplicar
docker exec wazuh.manager cp /var/ossec/etc/ossec.conf /var/ossec/etc/ossec.conf.bak
docker exec wazuh.manager cp /wazuh-config-mount/etc/ossec.conf /var/ossec/etc/ossec.conf
docker exec wazuh.manager /var/ossec/bin/wazuh-control restart

# 4. Verificar que coincide con el repositorio y que los agentes reconectan
docker cp wazuh.manager:/var/ossec/etc/ossec.conf /tmp/ossec.en-uso.conf
diff /tmp/ossec.en-uso.conf config/wazuh_cluster/wazuh_manager.conf && echo "alineado con el repo"
docker exec wazuh.manager /var/ossec/bin/agent_control -l
```

**Revertir:**

```bash
docker exec wazuh.manager cp /var/ossec/etc/ossec.conf.bak /var/ossec/etc/ossec.conf
docker exec wazuh.manager /var/ossec/bin/wazuh-control restart
```

> `docker compose restart wazuh.manager` **no** aplica los cambios, por la limitación
> descrita. `docker compose down -v` sí los aplica, pero borra agentes, llaves y alertas.

---

# 🔒 **Recomendaciones de Seguridad**

- Cambiar todas las contraseñas por defecto
- Restringir puertos con firewall (ufw, nftables)
- Usar HTTPS en producción
- Implementar políticas de backup automático
- Revisar logs de acceso y traps regularmente
- Mantener las imágenes de Docker actualizadas

---

# 📝 **Notas de Versión**

- **Zabbix 7.4.6** — Versión LTS estable
- **PostgreSQL 17.6** — Óptimo para cargas intensivas
- **Agent2** — Mejor capacidad para contenedores, plugins modernos

---

