# ssdt7.dsl (OEMACP): ACP _WOV and _DSD
/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of ssdt7.dat
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x000017CC (6092)
 *     Revision         0x02
 *     Checksum         0x02
 *     OEM ID           "AMD"
 *     OEM Table ID     "OEMACP"
 *     OEM Revision     0x00000001 (1)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20200717 (538969879)
 */
DefinitionBlock ("", "SSDT", 2, "AMD", "OEMACP", 0x00000001)
{
    External (_SB_.PCI0.GPPA.ACP_, DeviceObj)
    External (HA02, IntObj)

    Scope (\_SB.PCI0.GPPA.ACP)
    {
        Name (WOVS, 0x01)
        Method (_WOV, 0, NotSerialized)
        {
            Return (WOVS) /* \_SB_.PCI0.GPPA.ACP_.WOVS */
        }

        Name (_DSD, Package (0x02)  // _DSD: Device-Specific Data
        {
            ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
            Package (0x02)
            {
                Package (0x02)
                {
                    "acp-audio-zsc-enable", 
                    One
                }, 

                Package (0x02)
                {
                    "acp-audio-config-flag", 
                    0x10
                }
            }
        })
        Device (HDA0)
        {
            Name (_ADR, One)  // _ADR: Address
            Name (_DSD, Package (0x04)  // _DSD: Device-Specific Data
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x02)
                {
                    Package (0x02)
                    {
                        "acp-audio-device-interface-version", 
                        One
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-device-type", 
                        One
                    }
                }, 

                ToUUID ("dbb8e3e6-5886-4ba6-8795-1319f52a966b") /* Hierarchical Data Extension */, 
                Package (0x01)
                {
                    Package (0x02)
                    {
                        "acp-audio-device-eps", 
                        Package (0x02)
                        {
                            "PE00", 
                            "PE01"
                        }
                    }
                }
            })
            Name (PE00, Package (0x04)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x03)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-type", 
                        Zero
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-dsp-offload-supported", 
                        One
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-category", 
                        One
                    }
                }, 

                ToUUID ("dbb8e3e6-5886-4ba6-8795-1319f52a966b") /* Hierarchical Data Extension */, 
                Package (0x02)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-format", 
                        "FMTS"
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-fx-type-ex", 
                        "EFXS"
                    }
                }
            })
            Name (PE01, Package (0x04)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x03)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-type", 
                        Zero
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-dsp-offload-supported", 
                        One
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-category", 
                        0x02
                    }
                }, 

                ToUUID ("dbb8e3e6-5886-4ba6-8795-1319f52a966b") /* Hierarchical Data Extension */, 
                Package (0x02)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-format", 
                        "FMTH"
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-fx-type-ex", 
                        "EFXH"
                    }
                }
            })
            Name (FMTS, Package (0x02)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x03)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-format-max-channels", 
                        0x02
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-format-sampling-frequency", 
                        Package (0x01)
                        {
                            0xBB80
                        }
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-format-bits-per-sample", 
                        Package (0x01)
                        {
                            0x10
                        }
                    }
                }
            })
            Name (FMTH, Package (0x02)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x03)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-format-max-channels", 
                        0x02
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-format-sampling-frequency", 
                        Package (0x01)
                        {
                            0xBB80
                        }
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-format-bits-per-sample", 
                        Package (0x01)
                        {
                            0x10
                        }
                    }
                }
            })
            Name (EFXS, Package (0x02)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x03)
                {
                    Package (0x02)
                    {
                        "{05714B44-A61C-40F0-9F72-3A2EFF40D74C}", 
                        "{00000000-0000-0000-0000-000000000000}"
                    }, 

                    Package (0x02)
                    {
                        "{591689D6-7499-4444-BFDE-BA2BE1D9A5D6}", 
                        "{00000000-0000-0000-0000-000000000000}"
                    }, 

                    Package (0x02)
                    {
                        "{E5E0FB95-F997-4EB4-9580-35A81438FE5B}", 
                        "{CEFAB025-8A3F-4409-AD42-52CE4210D85E}"
                    }
                }
            })
            Name (EFXH, Package (0x02)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x02)
                {
                    Package (0x02)
                    {
                        "{591689D6-7499-4444-BFDE-BA2BE1D9A5D6}", 
                        "{00000000-0000-0000-0000-000000000000}"
                    }, 

                    Package (0x02)
                    {
                        "{E5E0FB95-F997-4EB4-9580-35A81438FE5B}", 
                        "{00000000-0000-0000-0000-000000000000}"
                    }
                }
            })
        }

        Device (PDMC)
        {
            Name (_ADR, 0x02)  // _ADR: Address
            If ((HA02 == One))
            {
                Name (_DSD, Package (0x04)  // _DSD: Device-Specific Data
                {
                    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                    Package (0x02)
                    {
                        Package (0x02)
                        {
                            "acp-audio-device-interface-version", 
                            One
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-device-type", 
                            0x02
                        }
                    }, 

                    ToUUID ("dbb8e3e6-5886-4ba6-8795-1319f52a966b") /* Hierarchical Data Extension */, 
                    Package (0x01)
                    {
                        Package (0x02)
                        {
                            "acp-audio-device-eps", 
                            Package (0x01)
                            {
                                "CE00"
                            }
                        }
                    }
                })
                Name (CE00, Package (0x04)
                {
                    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                    Package (0x0C)
                    {
                        Package (0x02)
                        {
                            "acp-audio-ep-type", 
                            One
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-voice-activation-supported", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-voice-activation-ddi-version", 
                            0x02
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-voice-activation-agents", 
                            Package (0x02)
                            {
                                0x04, 
                                0x40
                            }
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-startup-silence-supported", 
                            One
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-dsp-offload-supported", 
                            One
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-ultrasound-supported", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-software-loopback-supported", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-ai-noise-reduction-supported", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-default-gain", 
                            Package (0x02)
                            {
                                0x19, 
                                0x08
                            }
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-channel-order", 
                            Package (0x08)
                            {
                                One, 
                                Zero, 
                                Zero, 
                                Zero, 
                                Zero, 
                                Zero, 
                                Zero, 
                                Zero
                            }
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-kws-presets", 
                            Package (0x09)
                            {
                                0x02, 
                                0x42, 
                                Zero, 
                                One, 
                                0x02, 
                                0x0B01, 
                                One, 
                                Zero, 
                                One
                            }
                        }
                    }, 

                    ToUUID ("dbb8e3e6-5886-4ba6-8795-1319f52a966b") /* Hierarchical Data Extension */, 
                    Package (0x03)
                    {
                        Package (0x02)
                        {
                            "acp-audio-ep-format", 
                            "FMT0"
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-apo-fx-type-ex", 
                            "EFX0"
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-array-geometry", 
                            "EMAG"
                        }
                    }
                })
                Name (FMT0, Package (0x02)
                {
                    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                    Package (0x03)
                    {
                        Package (0x02)
                        {
                            "acp-audio-ep-format-max-channels", 
                            0x02
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-format-sampling-frequency", 
                            Package (0x01)
                            {
                                0xBB80
                            }
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-format-bits-per-sample", 
                            Package (0x01)
                            {
                                0x10
                            }
                        }
                    }
                })
                Name (EFX0, Package (0x02)
                {
                    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                    Package (0x03)
                    {
                        Package (0x02)
                        {
                            "{55345638-1547-4F78-91D7-20041BCA8B18}", 
                            "{00000000-0000-0000-0000-000000000000}"
                        }, 

                        Package (0x02)
                        {
                            "{65E94A28-DE71-4154-AD49-F67C7831EA4D}", 
                            "{00000000-0000-0000-0000-000000000000}"
                        }, 

                        Package (0x02)
                        {
                            "{E5B78E46-DAA2-4827-8D84-F6C0C0306541}", 
                            "{00000000-0000-0000-0000-000000000000}"
                        }
                    }
                })
                Name (EMAG, Package (0x04)
                {
                    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                    Package (0x09)
                    {
                        Package (0x02)
                        {
                            "acp-audio-ep-mic-array-version", 
                            0x0100
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-array-type", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-array-vertical-angle-begin", 
                            0xFFFFD718
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-array-vertical-angle-end", 
                            0x28E8
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-array-horizontal-angle-begin", 
                            0xFFFFDDE9
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-array-horizontal-angle-end", 
                            0x2217
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-array-frequency-band-lo", 
                            0x32
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-array-frequency-band-hi", 
                            0x4E20
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-array-number-of-microphones", 
                            0x02
                        }
                    }, 

                    ToUUID ("dbb8e3e6-5886-4ba6-8795-1319f52a966b") /* Hierarchical Data Extension */, 
                    Package (0x01)
                    {
                        Package (0x02)
                        {
                            "acp-audio-ep-mic-array-mic-coord", 
                            Package (0x02)
                            {
                                "MIC0", 
                                "MIC1"
                            }
                        }
                    }
                })
                Name (MIC0, Package (0x02)
                {
                    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                    Package (0x06)
                    {
                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-type", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-x", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-y", 
                            0xFFDF
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-z", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-vertical-angle", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-horizontal-angle", 
                            Zero
                        }
                    }
                })
                Name (MIC1, Package (0x02)
                {
                    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                    Package (0x06)
                    {
                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-type", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-x", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-y", 
                            0x21
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-z", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-vertical-angle", 
                            Zero
                        }, 

                        Package (0x02)
                        {
                            "acp-audio-ep-mic-coord-horizontal-angle", 
                            Zero
                        }
                    }
                })
            }
        }

        Device (I2SC)
        {
            Name (_ADR, 0x03)  // _ADR: Address
        }

        Device (BTSC)
        {
            Name (_ADR, 0x04)  // _ADR: Address
            Name (_DSD, Package (0x04)  // _DSD: Device-Specific Data
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x02)
                {
                    Package (0x02)
                    {
                        "acp-audio-device-interface-version", 
                        One
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-device-type", 
                        0x04
                    }
                }, 

                ToUUID ("dbb8e3e6-5886-4ba6-8795-1319f52a966b") /* Hierarchical Data Extension */, 
                Package (0x01)
                {
                    Package (0x02)
                    {
                        "acp-audio-device-eps", 
                        Package (0x02)
                        {
                            "PE00", 
                            "CE00"
                        }
                    }
                }
            })
            Name (PE00, Package (0x04)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x06)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-type", 
                        Zero
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-dsp-offload-supported", 
                        One
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-category", 
                        One
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-port", 
                        0x03
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-node", 
                        0x02
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-capabilities", 
                        Package (0x04)
                        {
                            One, 
                            0x02, 
                            0x04, 
                            0x08
                        }
                    }
                }, 

                ToUUID ("dbb8e3e6-5886-4ba6-8795-1319f52a966b") /* Hierarchical Data Extension */, 
                Package (0x03)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-format", 
                        "FMT0"
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-fx-type", 
                        "EFX0"
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-fx-type-ex", 
                        "EFX1"
                    }
                }
            })
            Name (FMT0, Package (0x02)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x03)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-format-max-channels", 
                        0x02
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-format-sampling-frequency", 
                        Package (0x03)
                        {
                            0x1F40, 
                            0x3E80, 
                            0xBB80
                        }
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-format-bits-per-sample", 
                        Package (0x01)
                        {
                            0x10
                        }
                    }
                }
            })
            Name (EFX0, Package (0x02)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x04)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-apo-efx-type", 
                        Zero
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-mfx-type", 
                        Zero
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-sfx-type", 
                        Zero
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-efx-encoder-type", 
                        0x0120
                    }
                }
            })
            Name (EFX1, Package (0x02)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x03)
                {
                    Package (0x02)
                    {
                        "{591689D6-7499-4444-BFDE-BA2BE1D9A5D6}", 
                        "{00000000-0000-0000-0000-000000000000}"
                    }, 

                    Package (0x02)
                    {
                        "{E5E0FB95-F997-4EB4-9580-35A81438FE5B}", 
                        "{00000000-0000-0000-0000-000000000000}"
                    }, 

                    Package (0x02)
                    {
                        "{09DF37AE-0217-4601-A842-DEC90EEBC68F}", 
                        "{66E5A40D-4559-4019-B0F1-5F842C7E461A}"
                    }
                }
            })
            Name (CE00, Package (0x04)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x05)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-type", 
                        One
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-dsp-offload-supported", 
                        One
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-ai-noise-reduction-supported", 
                        Zero
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-port", 
                        0x03
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-node", 
                        0x02
                    }
                }, 

                ToUUID ("dbb8e3e6-5886-4ba6-8795-1319f52a966b") /* Hierarchical Data Extension */, 
                Package (0x03)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-format", 
                        "FMT1"
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-fx-type", 
                        "EFX2"
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-fx-type-ex", 
                        "EFX3"
                    }
                }
            })
            Name (FMT1, Package (0x02)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x03)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-format-max-channels", 
                        0x02
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-format-sampling-frequency", 
                        Package (0x02)
                        {
                            0x1F40, 
                            0x3E80
                        }
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-format-bits-per-sample", 
                        Package (0x01)
                        {
                            0x10
                        }
                    }
                }
            })
            Name (EFX2, Package (0x02)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x04)
                {
                    Package (0x02)
                    {
                        "acp-audio-ep-apo-efx-type", 
                        Zero
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-mfx-type", 
                        Zero
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-sfx-type", 
                        Zero
                    }, 

                    Package (0x02)
                    {
                        "acp-audio-ep-apo-efx-encoder-type", 
                        0x0120
                    }
                }
            })
            Name (EFX3, Package (0x02)
            {
                ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301") /* Device Properties for _DSD */, 
                Package (0x03)
                {
                    Package (0x02)
                    {
                        "{65E94A28-DE71-4154-AD49-F67C7831EA4D}", 
                        "{00000000-0000-0000-0000-000000000000}"
                    }, 

                    Package (0x02)
                    {
                        "{E5B78E46-DAA2-4827-8D84-F6C0C0306541}", 
                        "{00000000-0000-0000-0000-000000000000}"
                    }, 

                    Package (0x02)
                    {
                        "{09DF37AE-0217-4601-A842-DEC90EEBC68F}", 
                        "{66E5A40D-4559-4019-B0F1-5F842C7E461A}"
                    }
                }
            })
        }

        Device (SDWC)
        {
            Name (_ADR, 0x05)  // _ADR: Address
        }

        Device (SDWS)
        {
            Name (_ADR, 0x06)  // _ADR: Address
        }

        Device (USBS)
        {
            Name (_ADR, 0x07)  // _ADR: Address
        }
    }
}

