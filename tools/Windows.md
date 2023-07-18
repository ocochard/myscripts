# Windows 11
## Install: avoid MS account creation

During install, "time to connect to a network"
During install, after keyboard setup, 2 options:
- No wire connection: "Oops, you’ve lost internet connection"
- Wire connected: "Let’s connect you to a network"

Use the "Shift + F10", then in command prompt to bypass network requierement:
```
oobe\bypassnro
```

It will reboot, and ask the same question again, but now you will have the
"No internet" option
