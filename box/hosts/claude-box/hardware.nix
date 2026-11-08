# Zotac ZBOX CI323 nano: Intel Celeron N3150 (Braswell/Airmont, no AVX),
# DDR3L, 2.5" SATA bay, 2x Realtek GbE, Intel 3165 Wi-Fi (unused).
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;
  powerManagement.cpuFreqGovernor = lib.mkDefault "schedutil";

  # Passive cooling: avoid sustained turbo heat, the box sits idle most of the time.
  services.thermald.enable = true;
}
