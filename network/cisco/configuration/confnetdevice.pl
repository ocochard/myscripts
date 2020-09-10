#!/usr/bin/perl
# Ce script permet de lancer une suite de commande sur l'ensemble des equipements reseaux
# Les commandes sont listees dans le fichier "commandes.liste"
# Les adresses IP sont dans les fichiers "liste.device" avec "device" representant le type d'equipement
# Un fichier de resultat est genere "log.typededevice.annemoisjourheureminute"
# Version 0.8 (découverte de perl, 2002), Olivier Cochard-Labbé <olivier@cochard.me>
# license: public domain

use Expect; # Utilisation du module Expect

#$Expect::Log_Stdout=1;

#Chargement du fichier de commandes

print "\nChargement du fichier contenant la liste des commandes 'liste.commandes'...";

$ListeCommandes = 'liste.commandes' ;
open(LISTECOMMANDES, "<$ListeCommandes" ) || die "\nNe peux lire le fichier $ListeCommandes: $!";
@commandes = <LISTECOMMANDES> ;
close(LISTECOMMANDES) ;

print "OK\n";

# Demande de l'utilisation du mode de test

until (($testonly eq "oui") or ($testonly eq "non")) {
        print "\nVoulez-vous activer le mode TEST (n'entre pas les commandes)? oui/non :";
        chomp($testonly=<STDIN>);
}
# Demande du nom du groupe d'equipement (fichier liste.nom-du-groupe)

while ($device eq "") {
        print "\nEntrez le nom du groupe d'equipement :" ;
        chomp($device=<STDIN>);
}

#Chargement du fichier de hosts

print "\nChargement du fichier contenant la liste des equipements...";

$ListeHosts = "liste.$device" ;
open(LISTEHOSTS, "<$ListeHosts" ) || die "\nNe peux lire le fichier $ListeHosts: $!";
@hosts = <LISTEHOSTS> ;
close(LISTEHOSTS) ;

print "OK\n";

# Demande du login a utiliser

print "\nEntrez le login (optionel): ";
chomp($user = <STDIN>) ;

while ($loginpass eq "") {
        print "\nEntrez le mot de passe (obligatoire): ";
        chomp($loginpass = <STDIN>) ;
}

while ($enablepass eq "") {
        print "\nEntrez le mot de passe Enable (obligatoire): ";
        chomp($enablepass = <STDIN>) ;
}

### Connexion sur les equipements

# Creation du fichier de log avec comme extension le type de device puis la date

# Appel de la fonction localtime
($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
$year+=1900; # ajout de 1900 a l'annee
$mon+=1; # ajout de 1 au mois car le premier est zero

print "\nCreation du fichier de log...";

open(LOG_FILE, ">log.${device}.${year}${mon}${mday}${hour}${min}") || die "\nNe peux ecrire dans le fichier log.$device: $!";

print "OK\n";

# Avertissement du fonctionnement en mode de test

if ($testonly==1) {
        print LOG_FILE "Mode Test: les commandes suivantes ne seront pas envoyees au equipement\n";
        }

# Insertion des commandes dans le fichier de log

print LOG_FILE "Liste des commandes entree:\n\n";
foreach $commande (@commandes) {
        last if $commande eq "\n" ; # Arret sur la premiere ligne vide
        next if /^#/; # va a la ligne suivante si commentaire
        chomp ($commande); # suppresion du caractere \n
        print LOG_FILE "$commande\n";
}
print LOG_FILE "-------------------------------\n";

#Boucle globale pour chaque device de la liste

HOST: foreach $host (@hosts) {
        chomp ($host);
        last HOST if $host eq "\n";
        next HOST if /^#/ ;
        print LOG_FILE "Host : $host\n";
        print LOG_FILE "------\n";

### Login sur l'equipement

        print LOG_FILE "Connexion a l'equipement...";
        $telnet=Expect->spawn("telnet $host");
        if ($telnet->expect(5,"Password: ")) {
                print $telnet "$loginpass\r";
        }
        else {
                print $telnet "\b$user\r";
                sleep 1;
                print $telnet "$loginpass\r";
        }
        $prompt  = '[\>]';
        if (!$telnet->expect(5,'-re',$prompt)) {
                print LOG_FILE "\nProbleme de login sur $host, ".$telnet->exp_error()."\n";
                $telnet->hard_close(); # Fermeture de la session
                next HOST; # On passe au suivant
        }
        print LOG_FILE "OK\n";

### Envoie de la configuration

        print LOG_FILE "Passage en mode Enable...";
        print $telnet "enable\r";
        sleep 1;
        if (!$telnet->expect(5,"Password: ")) {
                print LOG_FILE "\nNe reconnais pas la commande enable";
                $telnet->hard_close();
                next HOST;
        }
        print $telnet "$enablepass\r";
        $prompt = '[\#]';
        if (!$telnet->expect(5,'-re',$prompt)) {
                print LOG_FILE "\nProbleme de passage en mode Enable sur $host, ".$telnet->exp_error()."\n";
                $telnet->hard_close();
                next HOST;
        }
        print LOG_FILE "OK\n";

### Execution des commandes si on n'est pas en mode de test

        if ($testonly eq "oui") {
                $telnet->hard_close();
                next HOST;
        }

        print LOG_FILE "Envoie des commandes...";
        foreach $commande (@commandes) {
                chomp($commande);
                print $telnet "$commande\r";
                if (!$telnet->expect(20,'-re',$prompt)) {
                        print LOG_FILE "\nProbleme a la commande $commande sur $host, ".$telnet->exp_error()."\n";
               $telnet->hard_close();  # fermeture de la session
                next HOST; # On passe au suivant
                }
                sleep 1; # pause de 1 seconde entre chaque commande
        }
        print LOG_FILE "OK\n";

### Fermeture de Session

        print LOG_FILE "Ended for $host\n\n";
        $telnet->hard_close(); # Fermeture de la session

} # Fin de la boucle globale
close(LOG_FILE) || die "\nNe peux fermer le fichier log.$device : $!"; # Fermeture du fichier de log
