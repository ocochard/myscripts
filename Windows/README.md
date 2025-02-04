# Windows

## diskpart

[Official documentation](https://learn.microsoft.com/en-us/windows-server/storage/disk-management/shrink-a-basic-volume)

### Change volume size

Reducing partition size:
```
C:\>diskpart
DISKPART> list disk
DISKPART> select disk 1
DISKPART> list volume
DISKPART> select volume 2
DISKPART> shrink desired=4000 (in MB)
DISKPART> shrink minimum=2000 (in MB)
DISKPART> extend size=8000
```

### Create manually Windows partition scheme

Create [Windows boot drive](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions?view=windows-11) using this scheme:
- EFI
- Microsoft Reserved partition (msr)
- OS partiton
- Windows Recovery Environment partition (winre)

```
C:\>diskpart
DISKPART> list disk
DISKPART> select disk 3
DISKPART> clean
DISKPART> convert gpt
DISKPART> create partition efi size=100
DISKPART> create partition msr size=16
DISKPART> create partition primary
DISKPART> shrink minimum=450
DISKPART> format quick fs=ntfs label="Windows"
DISKPART> assign letter="W"
DISKPART> create partition primary id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
DISKPART> format quick fs=ntfs label=”Windows RE tools”
```

[Other examples with the deployement scripts](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/oem-deployment-of-windows-desktop-editions-sample-scripts)
