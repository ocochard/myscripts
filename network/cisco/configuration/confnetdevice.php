#!/usr/bin/php -f

<?php
/*

Ce script permet de lancer une suite de commande sur l'ensemble des equipements Cisco
Les commandes sont listees dans le fichier "commandes.liste"
Les adresses IP sont dans les fichiers "equipements.liste"
Un fichier de resultat est genere "log.typededevice.annemoisjourheureminute"
Version 0.2 (2005, découverte de PHP) par Olivier Cochard-Labbe <olivier@cochard.me>
license: public domain

Ce script utilise la fonction:

PHPCiscoTelnet 1.0 (http://linbox.free.fr/PHPCiscoTelnet.php)
adapted by Cyriac REMY (05/07/18)
adapted from code PHPTelnet 1.0 by Antone Roundy (http://www.geckotribe.com/php-telnet/)
originally adapted from code found on the PHP website
public domain
*/

include ("PHPCiscoTelnet.php");
$fp = fopen('php://stdin', 'r');

echo "\nEntrer le login: ";
$LOGIN = chop(fgets($fp));
if ($LOGIN === "") exit(0);

echo "\nEntrer le mot de passe: ";
$MOT_DE_PASSE = chop(fgets($fp));
if ($MOT_DE_PASSE === "") exit(0);

echo "\nEntrer le mot de passe enable: ";
$ENABLE_PASSWORD = chop(fgets($fp));

echo "\nChargement du fichier contenant la liste des commandes 'commandes.liste'...";
$FICHIER_LISTE_COMMANDES = "commandes.liste";
if (file_exists($FICHIER_LISTE_COMMANDES)) {
	$TABLEAU_COMMANDES = file($FICHIER_LISTE_COMMANDES);
	echo "OK\n";
} else {
	echo "pas OK\n";
	exit();
}

echo "\nChargement du fichier contenant la liste des adresses IP des equipements 'equipements.liste'...";
$FICHIER_LISTE_EQUIPEMENTS = "equipements.liste";
if (file_exists($FICHIER_LISTE_EQUIPEMENTS)) {
	$TABLEAU_EQUIPEMENTS = file($FICHIER_LISTE_EQUIPEMENTS);
	echo "OK\n";
} else {
	echo "pas OK\n";
	exit();
}

$DATE_DU_JOUR = date("Y-m-d-H-i");
echo "\n Creation du fichier log.txt\n";
$file_log = fopen("log.$DATE_DU_JOUR","w");
fputs($file_log, "Liste des commandes entrees:\n\n");
while(list($cle,$COMMANDE) = each($TABLEAU_COMMANDES)) { /* Creer une variable avec chaque ligne*/
	$COMMANDE = rtrim($COMMANDE);
	fputs($file_log, "Commande: $COMMANDE\n");
}

fputs($file_log, "--------------------------\n");
while(list($cle,$EQUIPEMENT) = each($TABLEAU_EQUIPEMENTS)) {
	$EQUIPEMENT = rtrim($EQUIPEMENT); /* supprime le dernier charactere de la variable si c'est un charactere special */
	fputs($file_log, "Equipement: $EQUIPEMENT\n");
	reset($TABLEAU_COMMANDES); /* Remet le pointeur du tableau a zeo sinon ca ne fonctionne que 1 fois*/
	$telnet = new PHPCiscoTelnet();
	$result = $telnet->Connect($EQUIPEMENT, $LOGIN, $MOT_DE_PASSE);
	switch ($result) {
		case 0:
			while(list($cle,$COMMANDE) = each($TABLEAU_COMMANDES)) { /* Creer une variable avec chaque ligne*/
				$COMMANDE = rtrim($COMMANDE);
				$telnet->enable($ENABLE_PASSWORD);
				$telnet->DoCommand($COMMANDE);
				fputs($file_log, "Commande: $COMMANDE... OK\n");
				$telnet->display();
			}
			$telnet->Disconnect();
			break;
		case 1:
			echo '[PHP Telnet] Connect failed: Unable to open network connection';
			break;
		case 2:
			echo '[PHP Telnet] Connect failed: Unknown host';
			break;
		case 3:
			echo '[PHP Telnet] Connect failed: Login failed';
			break;
		case 4:
			echo '[PHP Telnet] Connect failed: Your PHP version does not support PHP Telnet';
			break;
	}
}
fclose($file_log); /* ferme le fichier */
?>
