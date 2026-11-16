# ssdt2.dsl lines 1890-2300 and 2680-2700: Scope ACP power methods

        Name (_PR0, Package (0x01)  // _PR0: Power Resources for D0
        {
            PWRS, 
        })
        Name (_PR3, Package (0x01)  // _PR3: Power Resources for D3hot
        {
            PWRS, 
        })
    }

    Scope (\_SB.PCI0.GPPA.ACP)
    {
        Method (_S0W, 0, Serialized)  // _S0W: S0 Device Wake State
        {
            Local0 = Zero
            If ((\F5D3 != 0x55))
            {
                Local0 = \F5D3
            }

            M460 ("  OEM-ASL-PCIe Address (0x%X)._S0W ()  Return %d\n", DADR, Local0, Zero, Zero, Zero, Zero)
            Return (Local0)
        }

        Name (DADR, 0xEEEEEEEE)
        Name (DSTA, 0xEE)
        Name (DBUS, 0xEEEE)
        Name (PCSA, Zero)
        Name (PWST, 0xD3)
        Name (ESTA, 0xEE)
        Name (EBUS, 0xEEEE)
        Name (PW3S, Zero)
        Method (RPRM, 2, NotSerialized)
        {
            Local0 = Arg0
            OperationRegion (VARM, SystemMemory, Local0, 0x04)
            Field (VARM, AnyAcc, NoLock, Preserve)
            {
                VARR,   32
            }

            Local1 = VARR /* \_SB_.PCI0.GPPA.ACP_.RPRM.VARR */
            If ((Arg1 == One))
            {
                Local1 &= 0xFF
            }
            ElseIf ((Arg1 == 0x02))
            {
                Local1 &= 0xFFFF
            }
            ElseIf ((Arg1 == 0x03))
            {
                Local1 &= 0x00FFFFFF
            }

            M460 ("  OEM-ASL-PCIe Address (0x%X).RPRM (0x%X 0x%X) = 0x%X\n", DADR, Arg0, Arg1, Local1, Zero, Zero)
            Return (Local1)
        }

        Method (WPRM, 3, NotSerialized)
        {
            Local0 = Arg0
            If ((Arg1 == One))
            {
                OperationRegion (VARA, SystemMemory, Local0, One)
                Field (VARA, AnyAcc, NoLock, Preserve)
                {
                    VARE,   8
                }

                VARE = Arg2
            }
            ElseIf ((Arg1 == 0x02))
            {
                OperationRegion (VARB, SystemMemory, Local0, 0x02)
                Field (VARB, AnyAcc, NoLock, Preserve)
                {
                    VARF,   16
                }

                VARF = Arg2
            }
            ElseIf ((Arg1 == 0x03))
            {
                OperationRegion (VARC, SystemMemory, Local0, 0x03)
                Field (VARC, AnyAcc, NoLock, Preserve)
                {
                    VARG,   24
                }

                VARG = Arg2
            }
            Else
            {
                OperationRegion (VARD, SystemMemory, Local0, 0x04)
                Field (VARD, AnyAcc, NoLock, Preserve)
                {
                    VARH,   32
                }

                VARH = Arg2
            }

            M460 ("  OEM-ASL-PCIe Address (0x%X).WPRM (0x%X 0x%X 0x%X)\n", DADR, Arg0, Arg1, Arg2, Zero, Zero)
        }

        Method (SPDP, 1, NotSerialized)
        {
            Local5 = 0x7FFFFFFF
            Local5 |= 0x80000000
            Local2 = Zero
            Local0 = Zero
            While ((Local0 <= 0x1F))
            {
                Local1 = Zero
                While ((Local1 <= 0x07))
                {
                    Local3 = (((Arg0 << 0x14) & 0x0FF00000) | ((Local0 << 
                        0x0F) & 0x000F8000))
                    Local3 |= ((Local1 << 0x0C) & 0x7000)
                    Local4 = RPRM ((M083 + Local3), 0x04)
                    If (((Local4 != Local5) && (Local4 != Zero)))
                    {
                        Local2 |= (One << Local0)
                    }
                    ElseIf ((Local1 == Zero))
                    {
                        Break
                    }

                    Local1++
                }

                Local0++
            }

            M460 ("  OEM-ASL-PCIe Address (0x%X).SPDP (0x%X) = 0x%X\n", DADR, Arg0, Local2, Zero, Zero, Zero)
            Return (Local2)
        }

        Method (SPCH, 2, NotSerialized)
        {
            Local0 = Zero
            Local1 = RPRM ((Arg0 + 0x34), One)
            While ((Local1 != Zero))
            {
                Local2 = RPRM ((DADR + Local1), One)
                If (((Local2 == Zero) || (Local2 == 0xFF)))
                {
                    Break
                }

                If ((Local2 == Arg1))
                {
                    Local0 = Local1
                    Break
                }

                Local1 = RPRM ((DADR + (Local1 + One)), One)
            }

            M460 ("  OEM-ASL-PCIe Address (0x%X).SPCH (0x%X, 0x%X) = 0x%X\n", DADR, Arg0, Arg1, Local0, Zero, Zero)
            Return (Local0)
        }

        Method (_STA, 0, Serialized)  // _STA: Status
        {
            If (((DSTA == 0xEE) || (ESTA == 0xEE)))
            {
                If ((DBUS == 0xEEEE))
                {
                    If (CondRefOf (^^EBUS))
                    {
                        DBUS = ^^EBUS /* \_SB_.PCI0.GPPA.EBUS */
                    }
                    Else
                    {
                        DBUS = Zero
                    }
                }

                If ((DBUS != 0xEEEE))
                {
                    If ((DADR == 0xEEEEEEEE))
                    {
                        Local0 = (((_ADR << 0x0C) & 0x7000) | ((_ADR >> 
                            One) & 0x000F8000))
                        Local0 |= ((DBUS << 0x14) & 0x0FF00000)
                        DADR = (M083 + Local0)
                    }

                    Local0 = 0x7FFFFFFF
                    Local0 |= 0x80000000
                    Local1 = RPRM ((DADR + Zero), 0x04)
                    If (((Local1 == Local0) || (Local1 == Zero)))
                    {
                        DSTA = Zero
                        ESTA = Zero
                        If ((DBUS != Zero))
                        {
                            Local2 = ^^SPCH (^^DADR, 0x10)
                            If (((^^RPRM ((^^DADR + (Local2 + 0x14)), One) & 
                                0x40) == 0x40))
                            {
                                DSTA = 0x0F
                                ESTA = 0xEE
                            }
                        }
                    }
                    ElseIf ((RPRM ((DADR + 0x0A), 0x02) == 0x0604))
                    {
                        EBUS = RPRM ((DADR + 0x19), One)
                        Local2 = SPCH (DADR, 0x10)
                        If ((((RPRM ((DADR + (Local2 + 0x02)), 
                            One) >> 0x04) & 0x0F) == 0x05))
                        {
                            If ((EBUS == Zero))
                            {
                                DSTA = 0x0F
                                ESTA = 0xEE
                            }
                            ElseIf ((SPDP (EBUS) == Zero))
                            {
                                DSTA = Zero
                                ESTA = Zero
                            }
                            Else
                            {
                                DSTA = 0x0F
                                ESTA = 0x0F
                            }
                        }
                        ElseIf (((RPRM ((DADR + (Local2 + 0x1A)), 
                            One) & 0x40) == Zero))
                        {
                            If (((RPRM ((DADR + (Local2 + 0x14)), One) & 
                                0x40) == Zero))
                            {
                                DSTA = Zero
                                ESTA = Zero
                            }
                            Else
                            {
                                DSTA = 0x0F
                                ESTA = 0xEE
                            }
                        }
                        ElseIf ((EBUS == Zero))
                        {
                            DSTA = 0x0F
                            ESTA = 0xEE
                        }
                        Else
                        {
                            DSTA = 0x0F
                            ESTA = 0x0F
                        }
                    }
                    Else
                    {
                        DSTA = 0x0F
                        ESTA = Zero
                    }
                }
                Else
                {
                    DSTA = Zero
                    ESTA = 0xEE
                }
            }

            If ((((PCSA == One) && (PWST == 0xD3)) && (PW3S == One)))
            {
                PWST = 0xD0
            }

            If ((((PCSA == Zero) && (PWST == 0xD0)) && (PW3S == Zero)))
            {
                PWST = 0xD3
            }

            If (CondRefOf (SSTA))
            {
                SSTA ()
            }

            M460 ("  OEM-ASL-PCIe Address (0x%X)._STA = 0x%X  PWST = 0x%X  DBUS = 0x%X  ESTA = 0x%X  EBUS = 0x%X\n", DADR, DSTA, PWST, DBUS, ESTA, EBUS)
            Return (DSTA) /* \_SB_.PCI0.GPPA.ACP_.DSTA */
        }

        Method (_INI, 0, Serialized)  // _INI: Initialize
        {
            Local0 = 0x7FFFFFFF
            Local0 |= 0x80000000
            Local1 = RPRM ((DADR + Zero), 0x04)
            If (((Local1 == Local0) || (Local1 == Zero)))
            {
                PCSA = Zero
                PWST = 0xD3
                PW3S = Zero
            }
            Else
            {
                PCSA = One
                PWST = 0xD0
                PW3S = One
            }

            M460 ("  OEM-ASL-PCIe Address (0x%X)._INI  PCSA = 0x%X  PWST = 0x%X  PW3S = 0x%X\n", DADR, PCSA, PWST, PW3S, Zero, Zero)
            If (CondRefOf (SINI))
            {
                SINI ()
            }
        }

        Method (_REG, 2, Serialized)  // _REG: Region Availability
        {
            If (((Arg0 == 0x02) && (Arg1 == One)))
            {
                If ((DSTA == 0x0F))
                {
                    If (((RPRM ((DADR + 0x04), One) & 0xFC) == 0x04))
                    {
                        PCSA = One
                    }
                }
            }

            If (((Arg0 == 0x02) && (Arg1 == Zero)))
            {
                PCSA = Zero
            }

            If (CondRefOf (SREG))
            {
                SREG (Arg0, Arg1)
            }

            M460 ("  OEM-ASL-PCIe Address (0x%X)._REG (%d %d)  PCSA = %d\n", DADR, Arg0, Arg1, PCSA, Zero, Zero)
        }

        Method (_DSW, 3, Serialized)  // _DSW: Device Sleep Wake
        {
            If (CondRefOf (SDSW))
            {
                SDSW (Arg0, Arg1, Arg2)
            }

            M460 ("  OEM-ASL-PCIe Address (0x%X)._DSW (%d %d %d)  PCSA = %d\n", DADR, Arg0, Arg1, Arg2, PCSA, Zero)
        }

        PowerResource (PWRS, 0x00, 0x0000)
        {
            Method (_STA, 0, Serialized)  // _STA: Status
            {
                M460 ("  OEM-ASL-PCIe Address (0x%X).PWRS._STA = 0x%X\n", DADR, PW3S, Zero, Zero, Zero, Zero)
                If (CondRefOf (PSTA))
                {
                    PSTA ()
                }

                Return (PW3S) /* \_SB_.PCI0.GPPA.ACP_.PW3S */
            }

            Method (_ON, 0, Serialized)  // _ON_: Power On
            {
                If ((PW3S == Zero))
                {
                    PW3S = One
                    M460 ("  OEM-ASL-PCIe Address (0x%X).PWRS._ON = 0x%X\n", DADR, PW3S, Zero, Zero, Zero, Zero)
                    If (CondRefOf (P_ON))
                    {
                        P_ON ()
                    }
                }
            }

            Method (_OFF, 0, Serialized)  // _OFF: Power Off
            {
                If ((PW3S == One))
                {
                    PW3S = Zero
                    M460 ("  OEM-ASL-PCIe Address (0x%X).PWRS._OFF = 0x%X\n", DADR, PW3S, Zero, Zero, Zero, Zero)
                    If (CondRefOf (P_OF))
                    {
                        P_OF ()
                    }
                }
            }
        }

        Name (_PR0, Package (0x01)  // _PR0: Power Resources for D0
        {
            PWRS, 
        })
        Name (_PR3, Package (0x01)  // _PR3: Power Resources for D3hot
        {
            PWRS, 
        })
    }

    Scope (\_SB.PCI0.GPPA.HDEF)
    {
        Method (_S0W, 0, Serialized)  // _S0W: S0 Device Wake State
        {
            Local0 = Zero
            If ((\F6D3 != 0x55))
            {
                Local0 = \F6D3
            }
...
        })
    }

    Scope (\_SB)
    {
        Method (CK17, 0, NotSerialized)
        {
            Local0 = \_SB.PCI0.GPPA.RPRM ((\_SB.PCI0.GPPA.DADR + 0x54), 0x02)
            \_SB.PCI0.GPPA.WPRM ((\_SB.PCI0.GPPA.DADR + 0x54), 0x02, (Local0 & 0x7FFC))
            Local1 = \_SB.PCI0.GPPA.GFX0.RPRM ((\_SB.PCI0.GPPA.GFX0.DADR + 0x54), 0x02)
            Local1 = \_SB.PCI0.GPPA.HDAU.RPRM ((\_SB.PCI0.GPPA.HDAU.DADR + 0x54), 0x02)
            Local1 = \_SB.PCI0.GPPA.XHC1.RPRM ((\_SB.PCI0.GPPA.XHC1.DADR + 0x54), 0x02)
            Local1 = \_SB.PCI0.GPPA.ACP.RPRM ((\_SB.PCI0.GPPA.ACP.DADR + 0x54), 0x02)
            Local1 = \_SB.PCI0.GPPA.HDEF.RPRM ((\_SB.PCI0.GPPA.HDEF.DADR + 0x54), 0x02)
            \_SB.PCI0.GPPA.WPRM ((\_SB.PCI0.GPPA.DADR + 0x54), 0x02, (Local0 & 0x7FFF))
        }
    }

    Scope (\_GPE)
    {
        Method (_L19, 0, NotSerialized)  // _Lxx: Level-Triggered GPE, xx=0x00-0xFF
