#!/usr/libexec/flua
-- Discovering lua with a question: Could I use it to replace shell script?

-- function alias
-- s for shell
s=os.execute

-- Main function
local function main()
  local argument1 = arg[1]
  local argument2 = arg[2]
  word1 = "Hello"
  word2 = "World"
  print (word1 .. ", " .. word2 .. "!")
  if argument1 then
    print ("arg1: " .. argument1)
    if argument2 then
      print ("arg2: " .. argument2)
    end
  end
  print( "HOME env: " .. os.getenv("HOME"))
  os.execute([[echo "echo called by" "os.execute()"]])
  -- os.execute is too long to type, could we use shorter alias?
  s([[echo "echo called by alias s()"]])
end

main()
