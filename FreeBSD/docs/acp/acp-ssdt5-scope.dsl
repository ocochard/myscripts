# ssdt5.dsl Scope ACP
        }

        M460 ("FEA-ASL-CpmPowerGateOff-End\n", Zero, Zero, Zero, Zero, Zero, Zero)
        Release (M27E)
    }

    Scope (\_SB.PCI0.GPPA.ACP)
    {
        Method (_PS0, 0, NotSerialized)  // _PS0: Power State 0
        {
            M460 ("FEA-ASL-\\_SB.PCI0.PBC.ACP._PS0\n", Zero, Zero, Zero, Zero, Zero, Zero)
            M276 (Zero)
        }

        Method (_PS3, 0, NotSerialized)  // _PS3: Power State 3
        {
            M460 ("FEA-ASL-\\_SB.PCI0.PBC.ACP._PS3\n", Zero, Zero, Zero, Zero, Zero, Zero)
            M277 (Zero)
        }
    }

    Scope (\_SB.PCI0.GPPA.HDEF)
    {
        Method (_PS0, 0, NotSerialized)  // _PS0: Power State 0
        {
            M460 ("FEA-ASL-\\_SB.PCI0.PBC.HDEF._PS0\n", Zero, Zero, Zero, Zero, Zero, Zero)
            M276 (One)
        }

        Method (_PS3, 0, NotSerialized)  // _PS3: Power State 3
        {
            M460 ("FEA-ASL-\\_SB.PCI0.PBC.HDEF._PS3\n", Zero, Zero, Zero, Zero, Zero, Zero)
            M277 (One)
        }
    }
}

