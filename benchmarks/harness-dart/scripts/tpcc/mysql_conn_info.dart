/// MySQL connection info for bench scripts, configurable via env vars.
///
/// Default host is `127.0.0.1` (NOT `localhost`): libmysqlclient reads
/// `localhost` as a Unix socket, so the loopback IP is used to force TCP.
/// Inside Docker set MYSQL_HOST=mysql.
library;

import 'dart:io';

({String host, int port, String user, String password, String database})
    mysqlConn() {
  return (
    host: Platform.environment['MYSQL_HOST'] ?? '127.0.0.1',
    port: int.parse(Platform.environment['MYSQL_PORT'] ?? '3306'),
    user: Platform.environment['MYSQL_USER'] ?? 'root',
    password: Platform.environment['MYSQL_PASSWORD'] ?? '123',
    database: Platform.environment['MYSQL_DATABASE'] ?? 'teste',
  );
}
