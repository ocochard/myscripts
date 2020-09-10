' GDC ATM Switch Install
' Release 0.67
' License : Public domain
' Author: Olivier Cochard-Labbé <olivier@cochard.me>

Main()

Sub Main()

    RELEASE = "GDC ATM Switch Install for dummies - release 0.67"
    TEXT = "This tools will help you to erase all memory flash on a GDC ATM Switch"
    TEXT = TEXT & " and re-injecting the new firmware and configuration files" & vbCrLf & vbCrLf
    TEXT = TEXT & "Pre-requise:" & vbCrLf
    TEXT = TEXT & "You need to put GDC ATM firmware and configuration files" & vbCrLf
    TEXT = TEXT & "These subfolders must use this convention name:" & vbCrLf
    TEXT = TEXT & "- slot0 that contain a minimum of 3 files files: startup_isg.tz, config.cfg and hosts" & vbCrLf
    TEXT = TEXT & "- slot1 that contain files corresponding to the card type insered in this slot" & vbCrLf
    TEXT = TEXT & "- slot2, the same: files corresponding to the card type" & vbCrLf
    TEXT = TEXT & "- etc..." & vbCrLf& vbCrLf
    TEXT = TEXT & "Your IP configuration of your Workstation must be correctly configured with these parameters:" & vbCrLf
    TEXT = TEXT & " - IP address: 172.16.255.2" & vbCrLf
    TEXT = TEXT & " - IP MASK: 255.255.0.0" & vbCrLf
    TEXT = TEXT & " - IP Gateway: 172.16.255.1" & vbCrLf
    TEXT = TEXT & " and your NIC must be connected on the ATM Switch MGNT port of the STANDBY ISG card! (and not the ISG card on the slot0)" & vbCrLf & vbCrLf
    TEXT = TEXT & "Warning: Make sur your laptop is connected on the power supply outlet before starting this procedure" & vbCrLf & vbCrLf
    RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
    If RESPONSE = 2 Then
        wscript.quit
    End If

    Check_file()

    TEXT = "Step 2: Erasing all flash memory for each controler card:" & vbCrLf & vbCrLf
    TEXT = TEXT & "1. Power off the ATM switch" & vbCrLf& vbCrLf
    TEXT = TEXT & "2. Extract all cards (with the exception of XH cards) and change their rotary switch position to F" & vbCrLf & vbCrLf
    TEXT = TEXT & "3. Re-insert all cards and Power on the ATM switch" & vbCrLf & vbCrLf
    TEXT = TEXT & "4. Wait for the leds of each card (with the exception of EC2 cards) blink very fast :this indicates that the flash have been erased (aprox 5 minutes)" & vbCrLf & vbCrLf
    TEXT = TEXT & "5. Power off the ATM switch" & vbCrLf & vbCrLf

    TEXT = TEXT & "6. Change the rotary switch position by extracting each card (except for XH card):" & vbCrLf
    TEXT = TEXT & "- ISG card and Standby ISG card in position 1" & vbCrLf
    TEXT = TEXT & "- All other cards in position 9" & vbCrLf & vbCrLf
    TEXT = TEXT & "7. Re-insert only the standby ISG card (the XH card are still insered)" & vbCrLf & vbCrLf
    TEXT = TEXT & "8. Power on the ATM switch" & vbCrLf & vbCrLf
    TEXT = TEXT & "9. Wait until the ATM switch is running:" & vbCrLf & vbCrLf
    TEXT = TEXT & "- LED Status for standby ISG card: FLT and RUN are alternatively blinking" & vbCrLf & vbCrLf
    TEXT = TEXT & "Click OK only when ATM switch is ready"
    RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
    If RESPONSE = 2 Then
        wscript.quit
    End If

    iptest=check_ip("172.16.255.2","255.255.0.0","172.16.255.1")

    if iptest=0 then
        TEXT = "Your IP address is not configured correctly or interface down" & vbCrLf
        RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
        If RESPONSE = 2 Then
            wscript.quit
        End If
    End If

    TEXT = "Now, we will check IP connectivity by pinging the standby ISG card" & vbCrLf
    TEXT = TEXT & "Click OK for send a ping to the Standby ISG card"
    RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
    If RESPONSE = 2 Then
        wscript.quit
    End If

    Set WshShell = WScript.CreateObject("WScript.Shell")

    RETURNCODE = WshShell.Run("ping 172.16.255.1 -n 1", 1, True)
    if RETURNCODE > 0 then
        TEXT = "ERROR for ping the Standby ISG card!" & vbCrLf
        TEXT = TEXT & "Check your workstation IP configuration and cabling!" & vbCrLf
        RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
        If RESPONSE = 2 Then
            wscript.quit
        End If
    end if

    TEXT = "IP Connectivty is OK" & vbCrLf & vbCrLf
    TEXT = TEXT & "Step 3: Sending firmware file into the Standby ISG card." & vbCrLf
    TEXT = TEXT & "Click OK for proceding to files transfert"
    RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
    If RESPONSE = 2 Then
        wscript.quit
    End If

    FTP_isg()

    TEXT = "File should be transferted on the Standby ISG card" & vbCrLf & vbCrLf
    TEXT = TEXT & "Step 4: Sending initial configurations and hosts file into the ISG card." & vbCrLf & vbCrLf
    TEXT = TEXT & "1. Power off the ATM switch" & vbCrLf & vbCrLf
    TEXT = TEXT & "2. Unplug your workstation Ethernet cable from the standby ISG card and plug it on the ISG card" & vbCrLf & vbCrLf
    TEXT = TEXT & "3. Extract the Standby ISG card and change the rotary switch position to 4 but do not re-insert it!: This card will be insered only at the end of this procedure" & vbCrLf & vbCrLf
    TEXT = TEXT & "4. Re-insert all other cards with the expection of the Standby ISG card" & vbCrLf & vbCrLf
    TEXT = TEXT & "5. Power on the ATM switch" & vbCrLf & vbCrLf
    TEXT = TEXT & "6. Wait until the ATM switch is running:" & vbCrLf & vbCrLf
    TEXT = TEXT & "- LED Status for ISG card: FLT and RUN are alternatively blinking" & vbCrLf & vbCrLf
    TEXT = TEXT & "Click OK only when ATM switch is ready"
    RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
    If RESPONSE = 2 Then
        wscript.quit
    End If

    TEXT = "Now, we will check IP connectivity by pinging ISG card" & vbCrLf
    TEXT = TEXT & "Click OK for send a ping to the ISG"
    RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
    If RESPONSE = 2 Then
        wscript.quit
    End If

    RETURNCODE = WshShell.Run("ping 172.16.255.1 -n 1", 1, True)
    if RETURNCODE > 0 then
        TEXT = "ERROR for ping the ISG card!" & vbCrLf
        TEXT = TEXT & "Check your workstation IP configuration and cabling!" & vbCrLf
        RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
        If RESPONSE = 2 Then
            wscript.quit
        End If
    end if

    TEXT = "IP Connectivty is OK" & vbCrLf & vbCrLf
    TEXT = TEXT & "Step 5: Sending firmware and initial configuration files into the ISG." & vbCrLf
    TEXT = TEXT & "Click OK for proceding to files transfert"
    RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
    If RESPONSE = 2 Then
        wscript.quit
    End If

    FTP_isg()

    TEXT = "Step 6: Change the rotary switch of the ISG card (slot0) to 0"  & vbCrLf  & vbCrLf
    TEXT = TEXT & "1. Extract the ISG card (slot0) and put the rotary swith in position 0"  & vbCrLf & vbCrLf
    TEXT = TEXT & "2. Re-insert the ISG card (slot0)"  & vbCrLf & vbCrLf
    TEXT = TEXT & "3. Click OK ONLY when (after about 5 minutes):"  & vbCrLf & vbCrLf
    TEXT = TEXT & " - ISG card: The RUN led is solid green, and FLT led is off"  & vbCrLf
    TEXT = TEXT & " - XH cards: All RX leds are flashing orange"  & vbCrLf
    TEXT = TEXT & " - EC2 card (if present): Link Fault led is blinking"  & vbCrLf
    RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
    If RESPONSE = 2 Then
        wscript.quit
    End If

    TEXT = "Now, we will check IP connectivity for each slot"  & vbCrLf
    TEXT = TEXT & "Click OK for send the ping of the death"  & vbCrLf
    RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
    If RESPONSE = 2 Then
        wscript.quit
    End If

    RETURNCODE=ping_internal()
    if RETURNCODE > 0 then
        TEXT = "ERROR: Can't ping all slots!"  & vbCrLf
        TEXT = TEXT & "Use the procedure for a manual transfer :-("  & vbCrLf
        RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
        If RESPONSE = 2 Then
            wscript.quit
        End If
    end if

    TEXT = "Successfull ping all slots"  & vbCrLf & vbCrLf
    TEXT = TEXT & "Step 7: Sending all firmware and configuration files to each slot"  & vbCrLf
    TEXT = TEXT & "Click OK for starting the process"  & vbCrLf
    RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
    If RESPONSE = 2 Then
        wscript.quit
    End If

    RETURNCODE=files_upload()

    if RETURNCODE <> 0 then
        TEXT = "Error meet during file transfer!"  & vbCrLf
        TEXT = TEXT & "Use the procedure for a manual transfer :-("  & vbCrLf
        RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
        If RESPONSE = 2 Then
            wscript.quit
        End If
    end if

    TEXT = "Step 8: Setting definitive rotary switch parameter"  & vbCrLf & vbCrLf
    TEXT = TEXT & " 1. power off the ATM switch"  & vbCrLf  & vbCrLf
    TEXT = TEXT & " 2. Extract each card (with the exeption of ISG card that is allready in good boot mode, standby ISG card that is allready extracted and XH cards)" & vbCrLf  & vbCrLf
    TEXT = TEXT & " 3. Change Rotary switch position to 8 for each extracted card (with the expection of Standby ISG card that is keept in position 4 and ISG card keept in position 0)"  & vbCrLf  & vbCrLf
    TEXT = TEXT & " 4. Re-insert ALL cards (with the exeption of ISG and XH cards that are allready insered)"  & vbCrLf  & vbCrLf
    TEXT = TEXT & " 5. Power on your ATM switch"  & vbCrLf  & vbCrLf
    TEXT = TEXT & " 6. Wait until the switch has started (ISG card with green RUN LED, and Standby ISG with slowly blink RUN LED)"  & vbCrLf  & vbCrLf
    RESPONSE = MsgBox (TEXT,vbOk,RELEASE)

    clean()

End Sub

Sub clean()
    ' This sub delete all used file
    ' Call at the normal end only
    Set fso = CreateObject("Scripting.FileSystemObject")

    If (fso.FileExists("hosts")) Then
        fso.DeleteFile("hosts")
    end if

    If (fso.FileExists("ftpcommands.txt")) Then
        fso.DeleteFile("ftpcommands.txt")
    end if

    If (fso.FileExists("ftpslot0.txt")) Then
        fso.DeleteFile("ftpslot0.txt")
    end if


End Sub

Sub FTP_isg()

    Set WshShell = WScript.CreateObject("WScript.Shell")
    Set objFSO = CreateObject("Scripting.FileSystemObject")

    If (objFSO.FileExists("hosts")) Then
        objFSO.DeleteFile("hosts")
    end if

    Set HOSTSFILE = objFSO.CreateTextFile("hosts")
    HOSTSFILE.WriteLine ("ipaddress=10.10.10.10")
    HOSTSFILE.Close

    If (objFSO.FileExists("ftpcommands.txt")) Then
        objFSO.DeleteFile("ftpcommands.txt")
    end if

    Set objFile = objFSO.CreateTextFile("ftpcommands.txt")
    objFile.WriteLine ("root")
    objFile.WriteLine ("MANAGER")
    objFile.WriteLine ("bin")
    objFile.WriteLine ("hash")
    objFile.WriteLine ("get vconfig")
    objFile.WriteLine ("cd /mnt/flash0")
    objFile.WriteLine ("put slot0\startup_isg.tz")
    objFile.WriteLine ("put hosts")
    objFile.WriteLine ("bye")
    objFile.Close


    RETURNCODE = WshShell.Run("ftp -s:ftpcommands.txt 172.16.255.1", 1, True)

    If (objFSO.FileExists("vconfig")) Then
        objFSO.DeleteFile("vconfig")
    else
        RETURNCODE = RETURNCODE + 1
    end if

    if RETURNCODE > 0 then
        TEXT = "Error meet during the FTP transfert to the ISG card!" & vbCrLf
        TEXT = TEXT & "Use the procedure for a manual transfer :-("
        RESPONSE = MsgBox (TEXT,vbOkCancel,RELEASE)
        If RESPONSE = 2 Then
            wscript.quit
        End If
    end if


End Sub

Sub Generate_ftp_script()
    Set objFSO = CreateObject("Scripting.FileSystemObject")

    If (objFSO.FileExists("ftpslot0.txt")) Then
        objFSO.DeleteFile("ftpslot0.txt")
    end if

    Set objFile = objFSO.CreateTextFile("ftpslot0.txt")
    objFile.WriteLine ("root")
    objFile.WriteLine ("MANAGER")
    objFile.WriteLine ("bin")
    objFile.WriteLine ("hash")
    objFile.WriteLine ("get vconfig")
    objFile.WriteLine ("cd /mnt/flash0")

    set fso = CreateObject("Scripting.FileSystemObject")
    Set WshShell = WScript.CreateObject("WScript.Shell")
    'Get the sub folder list
    set SUBDIR_LIST =  fso.GetFolder(".").SubFolders

    For Each SUBDIR In SUBDIR_LIST
        set OBJ_FILE_LIST =  fso.GetFolder(SUBDIR.Path).Files

        if SUBDIR.Name = "slot0" then
            For Each OBJ_FILE In OBJ_FILE_LIST
                'Skip the startup file: Allready uploaded
                if OBJ_FILE.Name <> "startup_isg.tz" then
                    objFile.WriteLine ("put slot0\" & OBJ_FILE.Name)
                end if

            Next

        end if

    next

    objFile.WriteLine ("bye")
    objFile.Close

End Sub

Sub Check_file()

   ' Create the object
   TEXT = "Step 1: Checking firmware and configuration files presence and validity:" & vbCrLf
   TEXT = TEXT & "Check if your hardware ATM switch correspond to this configuration:" & vbCrLf & vbCrLf
    set fso = CreateObject("Scripting.FileSystemObject")
    'Get the sub folder list
    set SUBDIR_LIST =  fso.GetFolder(".").SubFolders

    If SUBDIR_LIST.Count = 0 Then

       MsgBox  "No slot directories found in script directory!" & vbCrLf & "There must be slot0, slot1, slot2, etc... directories that contain firmware and configurations files!"
        wscript.quit
    Else

        For Each SUBDIR In SUBDIR_LIST
            TEXT = TEXT & "- " & SUBDIR.Name & " "
            'Get the list of file in this sub folder
            set OBJ_FILE_LIST =  fso.GetFolder(SUBDIR.Path).Files

            FILE_CONFIG = 0
            FILE_STARTUP = 0
            FILE_HOSTS = 0
            FILE_VSM = 0
            FILE_MPRO = 0
            FILE_SLAVE = 0
            FILE_LCA = 0
            FILE_CE_LCA = 0
            FILE_ECC = 0
            FILE_EONE= 0
            FILE_OC= 0

            For Each OBJ_FILE In OBJ_FILE_LIST

                Select Case (OBJ_FILE.Name)

                Case "vsm.bin":
                    FILE_VSM = 1

                Case "mpro1.cod":
                    FILE_MPRO = 1

                Case "slave.cod":
                    FILE_SLAVE = 1

                Case "ce_lca.bin":
                    FILE_LCA = 1

                Case "ecc.cod":
                    FILE_ECC = 1

                Case "e1ds1.cod":
                    FILE_EONE = 1

                Case "oc3.cod":
                    FILE_OC = 1

                Case "hosts":
                    FILE_HOSTS = 1

                Case "startup_isg.tz":
                    FILE_STARTUP = 1

                Case "config.cfg":
                    FILE_CONFIG = 1

                End Select

            Next

            if FILE_CONFIG = 1 then
                if FILE_HOSTS=1 and FILE_STARTUP=1 then
                    TEXT = TEXT & "front: ISG, back: Empty" & vbCrLf
                elseif FILE_CONFIG=1 and FILE_VSM=1 and FILE_MPRO=1 then
                    TEXT = TEXT & "front: VSM, back: DS1-4CS" & vbCrLf
                elseif FILE_CONFIG=1 and FILE_MPRO=1 then
                    TEXT = TEXT & "front: ACP, back: E3-2C" & vbCrLf
                elseif FILE_CONFIG=1 and FILE_ECC=1 and FILE_EONE=1 then
                    TEXT = TEXT & "front: ECC/EC2, back: E1-IMA" & vbCrLf
                elseif FILE_CONFIG=1 and FILE_ECC=1 and FILE_OC=1 then
                    TEXT = TEXT & "front: ECC/EC2, back: 155I/M/H-2" & vbCrLf
                elseif FILE_CONFIG=1 and FILE_SLAVE=1 and FILE_LCA=1 then
                    TEXT = TEXT & "front: CE, back: SI-4C" & vbCrLf
                else
                    TEXT = TEXT & "Unknown!" & vbCrLf
                end if
            else
                TEXT = TEXT & "Missing config.cfg file!" & vbCrLf
            end if

        Next

        RESPONSE = MsgBox (TEXT,vbOkCancel,"Checking Switch Files presence")

        If RESPONSE = 2 Then
            wscript.quit
        End If

    End If

End Sub

Function files_upload()
    files_upload=0
    ' Create the object
    set fso = CreateObject("Scripting.FileSystemObject")
    Set WshShell = WScript.CreateObject("WScript.Shell")
    'Get the sub folder list
    set SUBDIR_LIST =  fso.GetFolder(".").SubFolders

    For Each SUBDIR In SUBDIR_LIST
        set OBJ_FILE_LIST =  fso.GetFolder(SUBDIR.Path).Files

        if SUBDIR.Name = "slot0" then
            ' Do not transfert slot0 in the begining, keept it for the last transfert
            'Must includ and loop exit here
            WScript.Sleep 1

        else
            'Extract the number of the folder name: slot1
            'create a 2 element array cuting using the 't'
            TEMPO = Split(SUBDIR.Name, "t", -1, 1)
            SLOT_IP = 10 + TEMPO(1)
            For Each OBJ_FILE In OBJ_FILE_LIST
                RETURNCODE = WshShell.Run("tftp -i 10.10.10." & SLOT_IP &" put " & SUBDIR.Name & "\" & OBJ_FILE.Name, 1, True)
                if RETURNCODE > 0 then

                    WScript.Sleep 1000
                    RETURNCODE = WshShell.Run("tftp -i 10.10.10." & SLOT_IP &" put " & SUBDIR.Name & "\" & OBJ_FILE.Name, 1, True)
                    if RETURNCODE > 0 then
                        TEXT = "Error for TFTP transfer file: " & OBJ_FILE.Name
                        TEXT = TEXT & " into slot IP 10.10.10." & SLOT_IP
                        MsgBox TEXT
                    end if
                end if
                WScript.Sleep 1000
                files_upload = files_upload + RETURNCODE
            Next

        end if

    next

    'After all card, we upload to the ISG card
    Generate_ftp_script()

    ' The return code is allways 0 (good) with FTP
    RETURNCODE = WshShell.Run("ftp -s:ftpslot0.txt 10.10.10.10", 1, True)

    ' the FTP script download the vconfig file, this permit to check if FTP connection works

    If (fso.FileExists("vconfig")) Then
        fso.DeleteFile("vconfig")
    else
        RETURNCODE = RETURNCODE + 1
    end if

    files_upload = files_upload + RETURNCODE


End Function

Function Ping_Internal()
    Ping_Internal=0
    ' Create the object
    set fso = CreateObject("Scripting.FileSystemObject")
    Set WshShell = WScript.CreateObject("WScript.Shell")
    'Get the sub folder list
    set SUBDIR_LIST =  fso.GetFolder(".").SubFolders

    For Each SUBDIR In SUBDIR_LIST
        set OBJ_FILE_LIST =  fso.GetFolder(SUBDIR.Path).Files
        'Extract the number of the folder name: slot1
        'create a 2 element array cuting using the 't'
        TEMPO = Split(SUBDIR.Name, "t", -1, 1)
        SLOT_IP = 10 + TEMPO(1)

        RETURNCODE = WshShell.Run("ping 10.10.10." & SLOT_IP & " -n 1", 1, True)
        Ping_Internal= Ping_Internal + RETURNCODE
    next

End Function

Function Ping_Internal_old()
    Ping_Internal=0
   ' Create the object
    set fso = CreateObject("Scripting.FileSystemObject")
    'Get the sub folder list
    set SUBDIR_LIST =  fso.GetFolder(".").SubFolders

    Set WshShell = WScript.CreateObject("WScript.Shell")

    LAST_IP = 10 + SUBDIR_LIST.Count - 1
    For INDEX = 10 To LAST_IP
        RETURNCODE = WshShell.Run("ping 10.10.10." & INDEX & " -n 1", 1, True)
        Ping_Internal= Ping_Internal + RETURNCODE
    Next

End Function

Function check_ip(ipaddress,mask,defaultipgateway)

    strComputer = "."
    Set objWMIService = GetObject("winmgmts:" _
    & "{impersonationLevel=impersonate}!\\" & strComputer & "\root\cimv2")

    Set IPConfigSet = objWMIService.ExecQuery _
    ("Select * from Win32_NetworkAdapterConfiguration Where IPEnabled=TRUE")

    foundip=0
    foundmask=0
    foundgw=0

    For Each IPConfig in IPConfigSet
        If Not IsNull(IPConfig.IPAddress) Then
            For i=LBound(IPConfig.IPAddress) to UBound(IPConfig.IPAddress)
                if IPConfig.IPAddress(i)=ipaddress then
                    foundip=1
                end if
                'WScript.Echo "DEBUG IP: " & IPConfig.IPAddress(i)
            Next
        End If
        If Not IsNull(IPConfig.DefaultIPGateway) Then
            For i=LBound(IPConfig.DefaultIPGateway) to UBound(IPConfig.DefaultIPGateway)
                if IPConfig.DefaultIPGateway(i)=defaultipgateway then
                    foundgw=1
                end if
                'WScript.Echo "DEBUG GW : " & IPConfig.DefaultIPGateway(i)
            Next
        End If
    Next

    check_ip = 0

    if foundip=1 and foundgw=1 then
        check_ip = 1
    end if

End Function
