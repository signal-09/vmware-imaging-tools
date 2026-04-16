# VMware ESXi Imaging Tools

## Requirements

Hardware:
* Enough disk space to host ISOs and disk images: ~50/100GB
* RAM: at least 16GB

These scripts require root privileges and rely on the following packages/commands:
* bash: `bash`
* curl: `curl`
* coreutils: `truncate`
* genisoimage: `mkisofs`
* qemu-system-x86: `qemu-system-x86_64`
* qemu-utils: `qemu-img`

KVM is not mandatory but highly recommended.

## Example

To create a VMware 7 compressed image with VNC connection for inspection and debug:

```shell
> ls -l

-rw-r--r-- 1 root root 401577984 Apr 16 14:11 VMware-VMvisor-Installer-7.0U3f-20036589.x86_64.iso
-rw-r--r-- 1 root root 648374272 Sep  3  2025 VMware-VMvisor-Installer-8.0U3e-24677879.x86_64.iso
-rwxr-xr-x 1 root root      5895 Apr 16 12:47 create-esxi-image.sh
-rw-r--r-- 1 root root       657 Sep  4  2025 ks.cfg

> ./create-esxi-image.sh --vnc --compress ./VMware-VMvisor-Installer-7.0U3f-20036589.x86_64.iso

Create custom ISO image...
VMware ISO image: ESXI-7.0U3F-20036589-STANDARD.iso
Install VMware from ISO...
VNC server running on 0.0.0.0:5900
Convert and compress VMware disk image (ESXI-7.0U3F-20036589-STANDARD.qcow2)...
```
