#!/bin/sh
# Send message to your telegram ID using the bot API
# Usage example: Server monitoring
# 1. First create your bot and get its token:
#    https://core.telegram.org/bots/tutorial#obtain-your-bot-token
# 2. Send send a dummy message to this new bot-user
# 3. Use this getUpdates call to receive updates from your bot, and extract
#    your user chat id from this message.
# 4. Ready to use!

set -eu

: ${TG_BOT_TOKEN:="telegram-bot-token"}
: ${TG_CHAT_ID:="telegram-chat-id"}

tg_api() {
  local args
  case $1 in
    getUpdates) action=GET;;
    sendMessage) action=POST;;
    *) exit 1;;
  esac
  curl -s -X ${action} "https://api.telegram.org/bot${TG_BOT_TOKEN}/$1" \
  -d chat_id="${TG_CHAT_ID}" \
  -d text="$2" \
  -d parse_mode="HTML"
}

message="<b>Hello world!</b>
This is a message from your bot"

if echo "${TG_BOT_TOKEN} ${TG_CHAT_ID}" | grep -q telegram; then
  echo "Usage:"
  echo "TG_BOT_TOKEN=\"1234567890:AABBB_CCCddddFFF1111\" TG_CHAT_ID=\"123456789\" $0"
  exit 1
fi

# To get the user chat id, once bot created, you need to send him a first
# message, then request this getUpdates to extract its ID
#tg_api getUpdates ""

tg_api sendMessage "${message}"
