#!/bin/sh

set -eu
# Default values
DICT="/usr/share/dict/words"
NUM_WORDS=3

usage() {
    echo "Usage: $(basename "$0") [-d DICT_FILE] [-n NUM_WORDS] [-h]"
    echo ""
    echo "Generate a passphrase using random words from a dictionary file."
    echo ""
    echo "Options:"
    echo "  -d DICT_FILE    Specify the dictionary file to use."
    echo "                  (Default: ${DICT})"
    echo "  -n NUM_WORDS    Specify the number of words for the passphrase."
    echo "                  (Default: ${NUM_WORDS})"
    echo "  -h              Display this help message and exit."
    echo ""
    exit 0
}

# Parse command-line options
while getopts "d:n:h" opt; do
    case "$opt" in
        d)
            DICT="$OPTARG"
            ;;
        n)
            # Basic validation: ensure NUM_WORDS is a positive integer
            if ! expr "$OPTARG" + 0 >/dev/null 2>&1 || [ "$OPTARG" -le 0 ]; then
                echo "Error: Number of words must be a positive integer." >&2
                exit 1
            fi
            NUM_WORDS="$OPTARG"
            ;;
        h)
            usage
            ;;
        \?)
            echo "Error: Invalid option -$OPTARG" >&2
            show_help
            ;;
    esac
done
shift $((OPTIND-1)) # Shift positional parameters past the options

# Validate DICT file existence
if [ ! -f "$DICT" ]; then
    echo "Error: Dictionary file '$DICT' not found." >&2
    exit 1
fi

# Count the number of lines in the dictionary
WORD_COUNT=$(wc -l < "$DICT" | awk '{print $1}')

if [ "$WORD_COUNT" -eq 0 ]; then
    echo "Error: Dictionary file '$DICT' is empty." >&2
    exit 1
fi

if [ "$NUM_WORDS" -gt "$WORD_COUNT" ]; then
    echo "Warning: Number of requested words ($NUM_WORDS) is greater than" >&2
    echo "         the total words in the dictionary ($WORD_COUNT)." >&2
    echo "         Using $WORD_COUNT words instead." >&2
    NUM_WORDS="$WORD_COUNT"
fi

# Generate random line numbers and pick words
PASSPHRASE=""
for i in $(seq 1 "$NUM_WORDS"); do
    # jot -r 1 MIN MAX: generates 1 random number between MIN and MAX
    RANDOM_LINE=$(jot -r 1 1 "$WORD_COUNT")
    # sed -n LINEp FILE: prints the specified line number from the file
    WORD=$(sed -n "${RANDOM_LINE}p" "$DICT" | tr -d '\n') # Get word and remove its newline
    PASSPHRASE="${PASSPHRASE}${WORD} " # Append word and a space
done

# Remove the trailing space if NUM_WORDS > 0 and a passphrase was generated
# The ${VAR%PATTERN} expansion safely handles empty strings as well.
echo "${PASSPHRASE% }"
