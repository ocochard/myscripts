MS Windows .vbs script.

This Script is used to guide an user to completly erase an GDC ATM switch (http://www.gdc.com/products/prod-broadband.html)
and send new firmware and configuration files on it.
For working, this script must found directory slot0,slot1,slot2, etc... containing requiered file

Example of file hierarchy needed for this script:
\switch1\slot0\startup_isg.tz
\switch1\slot0\config.cfg
\switch1\slot1\config.cfg
\switch1\slot1\mpro1.cod
etc..

This script will check the files and found the type of corresponding card type
