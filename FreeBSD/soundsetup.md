# hdaa2dot example: HP ZBook audio topology

Output of `hdaa2dot -m`, following the audio: playback pcm on the left, recording pcm on the right. Two HDA codecs (ATI HDMI, Realtek ALC245), the CS35L54 smart amplifiers behind the speaker pin, and the AMD ACP digital microphones attached directly to PCI.

```mermaid
flowchart LR
  subgraph hdaa1 ["hdaa1<br/>Realtek ALC245 Audio Function Group"]
    subgraph as_1_2 ["association group 2"]
      hdaa1_nid33["hdaa1:nid33<br/>Headphones,Jack,1/8,Left"]
    end
    subgraph as_1_1 ["association group 1"]
      hdaa1_nid23["hdaa1:nid23<br/>Speaker,Fixed,Analog,Internal"]
    end
    subgraph as_1_4 ["association group 4"]
      hdaa1_nid25["hdaa1:nid25<br/>Mic,Jack,1/8,Left"]
    end
  end
  subgraph hdaa0 ["hdaa0<br/>ATI R6xx Audio Function Group"]
    subgraph as_0_15 ["association group 15"]
      hdaa0_nid9["hdaa0:nid9<br/>Digital-out,Jack,Digital,0x18"]
      hdaa0_nid7["hdaa0:nid7<br/>Digital-out,Jack,Digital,0x18"]
      hdaa0_nid5["hdaa0:nid5<br/>Digital-out,Jack,Digital,0x18"]
      hdaa0_nid3["hdaa0:nid3<br/>Digital-out,Jack,Digital,0x18"]
    end
  end
  pci0_195_0_5["pci0:195:0:5<br/>Audio Coprocessor"] --> pcm6_rec["pcm6 rec<br/>AMD ACP 7.x digital microphones"]
  pcm5_play["pcm5 play<br/>Realtek ALC245 (Left Analog Headphones)"] --> hdaa1_nid33["hdaa1:nid33<br/>Headphones,Jack,1/8,Left"]
  pcm4_play["pcm4 play<br/>Realtek ALC245 (Analog)"] --> hdaa1_nid23["hdaa1:nid23<br/>Speaker,Fixed,Analog,Internal"]
  hdaa1_nid25["hdaa1:nid25<br/>Mic,Jack,1/8,Left"] --> pcm4_rec["pcm4 rec<br/>Realtek ALC245 (Analog)"]
  pcm3_play["pcm3 play<br/>ATI R6xx (HDMI)"] --> hdaa0_nid9["hdaa0:nid9<br/>Digital-out,Jack,Digital,0x18"]
  pcm2_play["pcm2 play<br/>ATI R6xx (HDMI)"] --> hdaa0_nid7["hdaa0:nid7<br/>Digital-out,Jack,Digital,0x18"]
  pcm1_play["pcm1 play<br/>ATI R6xx (HDMI)"] --> hdaa0_nid5["hdaa0:nid5<br/>Digital-out,Jack,Digital,0x18"]
  pcm0_play["pcm0 play<br/>ATI R6xx (HDMI)"] --> hdaa0_nid3["hdaa0:nid3<br/>Digital-out,Jack,Digital,0x18"]
  hdaa1_nid23["hdaa1:nid23<br/>Speaker,Fixed,Analog,Internal"] --> cs35l54_0["cs35l54.0<br/>Cirrus Logic CS35L54 speaker amplifiers, iicbus18 0x30"]
```
