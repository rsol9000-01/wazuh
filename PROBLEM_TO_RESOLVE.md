# Problema detectado en el despliegue de Wazuh con Docker Compose

## Resumen

El Dashboard de Wazuh iniciaba demasiado pronto, mientras el Indexer aún no estaba listo para aceptar conexiones. Esto provocó que el proceso de inicialización de OpenSearch Dashboards fallara en mitad de la migración de índices y dejara el sistema en un estado inconsistente.

## Síntoma observado

El servicio del Dashboard quedaba permanentemente en:

```text
Wazuh dashboard server is not ready yet
```

## Logs que evidencian el problema

Se observaron errores de conexión y fallos durante la creación de índices:

```text
[ConnectionError]: connect ECONNREFUSED 172.18.0.2:9200
[ResponseError]: Response Error
Starting saved objects migrations
Creating index .kibana_1
resource_already_exists_exception: index [.kibana_1] already exists
Another OpenSearch Dashboards instance appears to be migrating the index.
```

El mensaje más relevante fue el último, porque indicaba que la migración anterior había quedado incompleta y el Dashboard asumía que otra instancia seguía trabajando en ella.

## Causa raíz

La causa fue una sincronización defectuosa entre los servicios al arrancar.

- El Dashboard comenzó a trabajar antes de que el Indexer estuviera completamente listo.
- Los primeros errores fueron de conexión y timeout.
- La migración de índices quedó a medias.
- El resultado fue un índice `.kibana_1` creado de forma incompleta o corrupta.

## Solución aplicada

Se verificó la existencia del índice afectado:

```bash
curl -k -u admin:PASSWORD https://localhost:9200/_cat/indices/.kibana*?v
```

Se detectó que existía un índice `.kibana_1` vacío, por lo que se eliminó manualmente:

```bash
curl -k -u admin:PASSWORD -X DELETE https://localhost:9200/.kibana_1
```

Luego se reinició únicamente el Dashboard. En el siguiente arranque, el índice se recreó correctamente y la migración terminó de forma normal.

## Conclusión

El problema no era el Dashboard en sí, sino una condición de carrera entre el arranque del Indexer y el inicio de los demás servicios. Esto se puede corregir mejorando la lógica de inicio en Docker Compose.

## Propuesta de corrección en Docker Compose

No basta con usar `depends_on`, porque solo garantiza el orden de arranque de los contenedores, no que el servicio ya esté realmente listo para operar.

La idea es implementar una secuencia más robusta:

```text
Indexer
  ↓
Esperar healthcheck
  ↓
Manager
  ↓
Dashboard
```

### Opción recomendada

1. Agregar un healthcheck al Indexer que verifique:

```bash
https://localhost:9200/_cluster/health
```

2. Esperar a que devuelva un estado saludable, por ejemplo:

```json
"status":"green"
```

3. Configurar:

```yaml
depends_on:
  wazuh.indexer:
    condition: service_healthy
```

para el Manager y el Dashboard.

### Opción complementaria

Agregar un pequeño bucle de espera en el entrypoint del Dashboard (y de ser necesario del Manager) para verificar que el Indexer ya responda antes de continuar con la inicialización.

## Resultado esperado

Con estas mejoras, el despliegue será más robusto y se evitará volver a caer en el estado donde hay que borrar manualmente `.kibana_1` para recuperar el Dashboard.