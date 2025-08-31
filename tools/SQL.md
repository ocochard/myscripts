# MariaDB

## Simple installation for kodi

Example for kodi:

```
sudo pkg install mariadb118-server
sudo service mysql-server enable
sudo service mysql-server start
sudo mariadb-secure-installation
```

Now create kodi user:

```
mysql -u root -p
CREATE USER 'kodi' IDENTIFIED BY 'kodi';
GRANT ALL ON *.* TO 'kodi';
flush privileges;
quit;
```

To display all databases (that will be created by kodi):
```
SHOW DATABASES;
```

To display all users:
```
SELECT User FROM mysql.user;
```

## Backup and restoration

Backup:
```
mariadb-dump -u root -p --lock-tables --all-databases > dbs_alldatabases.sql
```

Restoration:
```
mariadb -u root -p < dbs_alldatabases.sql
```
