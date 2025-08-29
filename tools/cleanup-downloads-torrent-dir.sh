#!/bin/sh
# cleanup all files in Downloads not referenced by a .torrent
set -eu
downloads_dir=/zroot/data/downloads/
torrents_dir="${HOME}/.config/transmission-daemon/torrents/"
cd ${torrents_dir}
ls *.torrent | xargs -I {} transmission-show -f {} | awk '/^  / {sub(/^  /,""); sub(/ *\([^)]*\)$/,""); print}' > /tmp/torrents.list
cd ${downloads_dir}
find . -type f | sed 's|^\./||' > /tmp/downloads.list
for f in /tmp/torrents.list /tmp/downloads.list; do
	sort -o $f.sorted $f
	rm $f
done
echo "List of not referenced files in ${download_dir}:"
diff /tmp/downloads.list.sorted /tmp/torrents.list.sorted | grep '^<'
