#!/bin/sh
# Crea (o resincroniza) el usuario 'exporter' en los 4 MySQL de landslide con
# el password de secret/mysqld-exporter. Correr en el nodo, con kubectl:
#
#   sudo sh mysql-exporter-user.sh
#
# El usuario no lo crea el initdb, así que se pierde si se reinicia el datadir
# (pasó el 2026-09-15: mysql_up=0 en los 4 exporters hasta el 2026-09-23).
# Idempotente: crea el usuario si falta y le resetea el password si ya existe.
# El password nunca se imprime.
set -e
PW=$(kubectl -n landslide get secret mysqld-exporter -o jsonpath='{.data.password}' | base64 -d)
PW_SQL=$(printf '%s' "$PW" | sed "s/'/''/g")
for s in data-management early-warning project-management user-management; do
  echo "== mysql-$s-0"
  kubectl -n landslide exec -i mysql-$s-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<SQL
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY '$PW_SQL' WITH MAX_USER_CONNECTIONS 3;
ALTER USER 'exporter'@'%' IDENTIFIED BY '$PW_SQL' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
SQL
done
# Los exporters reconectan en cada scrape; no hace falta reiniciarlos.
