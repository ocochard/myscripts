# find (some example)

Moving all mkv files that are in their respective sub-directory in the same directory

```
find . -name \*.mkv | xargs -I '{}' mv '{}' .
```

Displaying file size of all *.sh:
```
find . -name \*.sh | xargs -I '{}' ls -lh '{}'
```
