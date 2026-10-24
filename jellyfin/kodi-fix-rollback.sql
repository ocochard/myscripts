-- smb://192.168.100.1/films/Divers/Kick.Ass.2010.2160p.mkv
START TRANSACTION;
UPDATE movie SET c00='Millénium 3 : La Reine dans le palais des courants d\'air', c16='Luftslottet som sprängdes', premiered='2009-11-27' WHERE idMovie=5303;
DELETE FROM uniqueid WHERE media_id=5303 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (5303, 'movie', 'tt1343097', 'imdb');
DELETE FROM uniqueid WHERE media_id=5303 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (5303, 'movie', '33613', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=5303;
COMMIT;

-- smb://192.168.100.1/films/Cours.metrage/Pixar/Jour.nuit.1080p.mkv
START TRANSACTION;
UPDATE movie SET c00='Ce que le jour doit à la nuit', c16='Ce que le jour doit à la nuit', premiered='2012-09-12' WHERE idMovie=2022;
DELETE FROM uniqueid WHERE media_id=2022 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (2022, 'movie', 'tt1934205', 'imdb');
DELETE FROM uniqueid WHERE media_id=2022 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (2022, 'movie', '119193', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=2022;
COMMIT;

-- smb://192.168.100.1/films/Divers/The.Insider.2025.2160p.mkv
START TRANSACTION;
UPDATE movie SET c00='Infiltrada en el búnker', c16='Infiltrada en el búnker', premiered='2025-06-27' WHERE idMovie=6317;
DELETE FROM uniqueid WHERE media_id=6317 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6317, 'movie', 'tt37319756', 'imdb');
DELETE FROM uniqueid WHERE media_id=6317 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6317, 'movie', '1317931', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=6317;
COMMIT;

-- smb://192.168.100.1/films/Dessin.Anime/En.route.2015.720p.mkv
START TRANSACTION;
UPDATE movie SET c00='Mad Max : Fury Road', c16='Mad Max: Fury Road', premiered='2015-05-13' WHERE idMovie=5941;
DELETE FROM uniqueid WHERE media_id=5941 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (5941, 'movie', 'tt1392190', 'imdb');
DELETE FROM uniqueid WHERE media_id=5941 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (5941, 'movie', '76341', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=5941;
COMMIT;

-- smb://192.168.100.1/films/Divers/Desert.Gun.2016.1080p.mkv
START TRANSACTION;
UPDATE movie SET c00='Les Derniers jours dans le désert', c16='Last Days in the Desert', premiered='2016-05-13' WHERE idMovie=5697;
DELETE FROM uniqueid WHERE media_id=5697 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (5697, 'movie', 'tt3513054', 'imdb');
DELETE FROM uniqueid WHERE media_id=5697 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (5697, 'movie', '310119', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=5697;
COMMIT;

-- smb://192.168.100.1/films/Divers/The.Hunt.2012.1080p.mkv
START TRANSACTION;
UPDATE movie SET c00='La Chasse', c16='Jagten', premiered='2012-06-13' WHERE idMovie=6385;
DELETE FROM uniqueid WHERE media_id=6385 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6385, 'movie', 'tt2106476', 'imdb');
DELETE FROM uniqueid WHERE media_id=6385 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6385, 'movie', '103663', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=6385;
COMMIT;

-- smb://192.168.100.1/films/Dessin.Anime/Les.Rebelles.de.la.foret.720p.avi
START TRANSACTION;
UPDATE movie SET c00='Les Rebelles de la forêt 2', c16='Open Season 2', premiered='2008-09-24' WHERE idMovie=6026;
DELETE FROM uniqueid WHERE media_id=6026 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6026, 'movie', 'tt1107365', 'imdb');
DELETE FROM uniqueid WHERE media_id=6026 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6026, 'movie', '13690', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=6026;
COMMIT;

-- smb://192.168.100.1/films/Documentaires/Egypt.2013.1080p.mkv
START TRANSACTION;
UPDATE movie SET c00='Les Pyramides d\'Égypte', c16='Les Pyramides d\'Égypte', premiered='2013-06-26' WHERE idMovie=3971;
DELETE FROM uniqueid WHERE media_id=3971 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (3971, 'movie', 'tt4800364', 'imdb');
DELETE FROM uniqueid WHERE media_id=3971 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (3971, 'movie', '442099', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=3971;
COMMIT;

-- smb://192.168.100.1/films/Francais/Fanfan.la.Tulipe.2003.1080p.mkv
START TRANSACTION;
UPDATE movie SET c00='Fanfan la Tulipe', c16='Fanfan la Tulipe', premiered='1952-03-20' WHERE idMovie=4528;
DELETE FROM uniqueid WHERE media_id=4528 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (4528, 'movie', 'tt0044602', 'imdb');
DELETE FROM uniqueid WHERE media_id=4528 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (4528, 'movie', '62547', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=4528;
COMMIT;

-- smb://192.168.100.1/films/Francais/L'Adieu.2019.2160p.mkv
START TRANSACTION;
UPDATE movie SET c00='L\'Adieu à la nuit', c16='L\'Adieu à la nuit', premiered='2019-04-24' WHERE idMovie=5699;
DELETE FROM uniqueid WHERE media_id=5699 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (5699, 'movie', 'tt8569390', 'imdb');
DELETE FROM uniqueid WHERE media_id=5699 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (5699, 'movie', '575458', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=5699;
COMMIT;

-- smb://192.168.100.1/films/Animation/Space.Battleship.Yamato.2199.2014.1080p.mkv
START TRANSACTION;
UPDATE movie SET c00='Space Battleship Yamato 2199 - A Voyage to Remember', c16='宇宙戦艦ヤマト2199 追憶の航海', premiered='2014-10-11' WHERE idMovie=6458;
DELETE FROM uniqueid WHERE media_id=6458 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6458, 'movie', 'tt3689894', 'imdb');
DELETE FROM uniqueid WHERE media_id=6458 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6458, 'movie', '500626', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=6458;
COMMIT;

-- smb://192.168.100.1/films/Fantastique.SF/Coma.2019.1080p.mkv
START TRANSACTION;
UPDATE movie SET c00='Coma : Esprits prisonniers', c16='Кома', premiered='2019-11-19' WHERE idMovie=4073;
DELETE FROM uniqueid WHERE media_id=4073 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (4073, 'movie', 'tt6087226', 'imdb');
DELETE FROM uniqueid WHERE media_id=4073 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (4073, 'movie', '430155', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=4073;
COMMIT;

-- smb://192.168.100.1/films/Francais/Podium.2003.mkv
START TRANSACTION;
UPDATE movie SET c00='Podium', c16='Podium', premiered='2004-02-11' WHERE idMovie=4757;
DELETE FROM uniqueid WHERE media_id=4757 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (4757, 'movie', 'tt0354836', 'imdb');
DELETE FROM uniqueid WHERE media_id=4757 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (4757, 'movie', '14648', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=4757;
COMMIT;

-- smb://192.168.100.1/films/Fantastique.SF/Solace.2015.MULTi.1080p.mkv
START TRANSACTION;
UPDATE movie SET c00='Prémonitions', c16='Solace', premiered='2015-09-03' WHERE idMovie=4286;
DELETE FROM uniqueid WHERE media_id=4286 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (4286, 'movie', 'tt1291570', 'imdb');
DELETE FROM uniqueid WHERE media_id=4286 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (4286, 'movie', '339527', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=4286;
COMMIT;

-- smb://192.168.100.1/films/Francais/Belladone.2025.1080p.mkv
START TRANSACTION;
UPDATE movie SET c00='Belladone', c16='Belladone', premiered='2025-03-26' WHERE idMovie=6297;
DELETE FROM uniqueid WHERE media_id=6297 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6297, 'movie', 'tt13872390', 'imdb');
DELETE FROM uniqueid WHERE media_id=6297 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6297, 'movie', '1186830', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=6297;
COMMIT;

-- smb://192.168.100.1/films/Animation/Albator.84.L.atlantis.de.Ma.Jeunesse.1982.1080p.mkv
START TRANSACTION;
UPDATE movie SET c00='Albator 84 - L\'Atlantis de ma jeunesse', c16='わが青春のアルカディア', premiered='1982-07-28' WHERE idMovie=6190;
DELETE FROM uniqueid WHERE media_id=6190 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6190, 'movie', 'tt0084881', 'imdb');
DELETE FROM uniqueid WHERE media_id=6190 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6190, 'movie', '42137', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=6190;
COMMIT;

-- smb://192.168.100.1/films/Animation/Flow.2024.2160p.mkv
START TRANSACTION;
UPDATE movie SET c00='Flow, le chat qui n\'avait plus peur de l\'eau', c16='Straume', premiered='2024-01-30' WHERE idMovie=6212;
DELETE FROM uniqueid WHERE media_id=6212 AND media_type='movie' AND type='imdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6212, 'movie', 'tt4772188', 'imdb');
DELETE FROM uniqueid WHERE media_id=6212 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6212, 'movie', '823219', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=6212;
COMMIT;

-- smb://192.168.100.1/films/Dessin.Anime/Le.Roi.Lion.2019.2160p.mkv
START TRANSACTION;
UPDATE movie SET c00='Explorez le Festival du Roi Lion & de la Jungle', c16='Explorez le Festival du Roi Lion & de la Jungle', premiered='2019-07-26' WHERE idMovie=6009;
DELETE FROM uniqueid WHERE media_id=6009 AND media_type='movie' AND type='imdb';
DELETE FROM uniqueid WHERE media_id=6009 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6009, 'movie', '620073', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=6009;
COMMIT;

-- smb://192.168.100.1/films/Fantastique.SF/The.fantastic.four.first.steps.2025.2160p.mkv
START TRANSACTION;
UPDATE movie SET c00='Marvel Studios\' The Fantastic Four: First Steps - World Premiere', c16='Marvel Studios\' The Fantastic Four: First Steps - World Premiere', premiered='2025-07-21' WHERE idMovie=6410;
DELETE FROM uniqueid WHERE media_id=6410 AND media_type='movie' AND type='imdb';
DELETE FROM uniqueid WHERE media_id=6410 AND media_type='movie' AND type='tmdb';
INSERT INTO uniqueid (media_id, media_type, value, type) VALUES (6410, 'movie', '1516738', 'tmdb');
UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie=6410;
COMMIT;

