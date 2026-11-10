-- HDR films indexed by Jellyfin (SQLite, WAL mode: open read-only with
-- sqlite3 "file:/var/db/jellyfin/data/jellyfin.db?immutable=1" < this file).
-- Replace /path/to/films below with your film library root ($FILMS).
-- 1) Count of HDR video streams by codec, transfer, Dolby Vision profile, HDR10+.
SELECT m.StreamType, m.Codec, m.ColorTransfer, IFNULL(m.DvProfile,'-'),
    IFNULL(m.Hdr10PlusPresentFlag,'-'), COUNT(*)
FROM MediaStreamInfos m JOIN BaseItems b ON b.Id = m.ItemId
WHERE m.ColorTransfer IN ('smpte2084','arib-std-b67') AND b.Path LIKE '/path/to/films/%'
GROUP BY 1,2,3,4,5 ORDER BY 6 DESC;
-- 2) HDR10 HEVC films with genres, in random order (to pick films per genre).
.mode list
.separator |
SELECT b.Genres, b.ProductionYear, m.Width||'x'||m.Height, IFNULL(m.DvProfile,'-'), b.Path
FROM MediaStreamInfos m JOIN BaseItems b ON b.Id = m.ItemId
WHERE m.StreamType = 1 AND m.Codec = 'hevc' AND m.ColorTransfer = 'smpte2084'
  AND b.Path LIKE '/path/to/films/%'
ORDER BY random();
