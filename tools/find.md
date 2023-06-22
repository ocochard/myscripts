# find (some example)

Moving all mkv files that are in their respective sub-directory in the same directory

```
find . -name \*.mkv | xargs -I '{}' mv '{}' .
```
