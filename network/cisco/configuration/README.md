Voici 2 scripts (perl et php), qui permettent de:

Lancer une suite de commande (à entrer dans le fichier liste.commandes)
Sur un groupe d'équipements (mettre leurs adresses IP dans le/les fichiers liste.nom-du-groupe)
Le résultat étant enregistré dans un fichier de logs ayant pour nom: log.device.dateheure)

Pré requis pour la version perl:
 - Module IO-Tty pour Perl
 - Module Expect pour Perl

ToDo List:
 - Utliser le module telnet et/ou ssh
 - Rediriger la sortie vers un fichier de logs

Exemple d'un fichier liste.nom-du-groupe:
```
172.16.1.1
172.16.1.2
172.16.1.3
````

Exemple d'un fichier commandes.liste:

```
conf t
ntp server 192.168.1.1
exit
wr
```
