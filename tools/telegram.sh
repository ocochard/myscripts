#!/bin/sh
# Send message to your telegram ID using the bot API
# Usage example: Server monitoring

set -eu

config_file=/etc/tg.creds
os=$(uname -o)

# Check if credentials saved
if [ -f ${config_file} ]; then
  case $os in
    "FreeBSD") perm=$(stat -f "%Lp" ${config_file});;
    "GNU/Linux") perm=$(stat -c "%a" ${config_file});;
    *) echo "Unsuported os ($os)" && exit 1;;
  esac
  if [ "${perm}" -ne 600 ]; then
    echo "Permission on file /etc/rc.conf (${perm}) should be restricted to 600"
  fi
. ${config_file}
fi

: ${TG_BOT_TOKEN:="telegram-bot-token"}
# Receiver id of your message:
: ${TG_CHAT_ID:="telegram-chat-id"}
: ${TG_MSG="<b>Hello world!</b>
This is a message from your bot"}

tg_api() {
  local args
  case $1 in
    getUpdates) action=GET;;
    sendMessage) action=POST;;
    *) echo "Unknown action ($1)" && usage && exit 1;;
  esac
  curl -s -X ${action} "https://api.telegram.org/bot${TG_BOT_TOKEN}/$1" \
  -d chat_id="${TG_CHAT_ID}" \
  -d text="${TG_MSG}" \
  -d parse_mode="HTML"
}

usage () {
  echo "Usage:"
  echo "1. First create your bot and get its token:"
  echo "   https://core.telegram.org/bots/tutorial#obtain-your-bot-token"
  echo "   And copy it to set variable TG_BOT_TOKEN"
  echo "2. Send send a dummy message to this new bot-user"
  echo "3. Extract your sender user id by using getUpdates"
  echo "   TG_BOT_TOKEN=\"123:AABBB_CCC...\" $0 getUpdates"
  echo "   And copy it to set variable TG_CHAT_ID"
  echo "4. Send message:"
  echo "   TG_BOT_TOKEN=\"123:AABBB_...\" TG_CHAT_ID=\"123\" $0 sendMessage \"message\""
}

if [ $# -lt 1 ] || echo "${TG_BOT_TOKEN}" | grep -q telegram; then
  usage
  exit 1
fi

if [ $# -gt 1 ]; then
  TG_MSG="$2"
fi

tg_api "$1"
