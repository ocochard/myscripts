#!/bin/sh
# Passphrase generator

DICT="/usr/share/dict/words"
NUM_WORDS=3

# Count the number of lines in the dictionary
WORD_COUNT=$(wc -l < "$DICT" | awk '{print $1}')

# Generate random line numbers and pick words
# Collect words into a single string with spaces
PASSPHRASE=""
for i in $(seq 1 $NUM_WORDS); do
    RANDOM_LINE=$(jot -r 1 1 $WORD_COUNT)
    WORD=$(sed -n "${RANDOM_LINE}p" "$DICT" | tr -d '\n') # Get word and remove its newline
    PASSPHRASE="${PASSPHRASE}${WORD} " # Append word and a space
done

# Remove the trailing space if NUM_WORDS > 0
echo "${PASSPHRASE% }" # Use shell parameter expansion to remove trailing space
