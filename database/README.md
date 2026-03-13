kubectl create secret generic mysql-secret \
  --from-literal=MYSQL_ROOT_PASSWORD=password \
  --from-literal=MYSQL_USER=fastapiuser \
  --from-literal=MYSQL_PASSWORD=fastapipass \
  --from-literal=MYSQL_DATABASE=fastapidb
