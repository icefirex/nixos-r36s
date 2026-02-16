# Hardware configuration for R36S (Rockchip RK3326)
{ config, lib, pkgs, ... }:

let
  # Out-of-tree ROCKNIX generic-dsi panel driver.
  # Reads init sequences from device tree. Used with NV3051D panel (ArkOS "Panel 4").
  panelGenericDsi = { lib, kernel }:
    kernel.stdenv.mkDerivation {
      pname = "panel-generic-dsi";
      version = kernel.version;
      src = ./drivers;

      nativeBuildInputs = kernel.moduleBuildDependencies;

      buildPhase = ''
        make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
          M=$PWD \
          ARCH=${kernel.stdenv.hostPlatform.linuxArch} \
          CROSS_COMPILE=${kernel.stdenv.cc.targetPrefix} \
          modules
      '';

      installPhase = ''
        install -D panel-generic-dsi.ko \
          $out/lib/modules/${kernel.modDirVersion}/extra/panel-generic-dsi.ko
      '';

      meta = {
        description = "Generic MIPI-DSI panel driver (ROCKNIX)";
        license = lib.licenses.gpl2Only;
        platforms = [ "aarch64-linux" ];
      };
    };

  # Pre-built U-Boot from Armbian for R36S (RK3326).
  # Extracted from armbian-r36s-bookworm-minimal.img sectors 64-32768.
  # Includes idbloader (TPL+SPL), ATF, and U-Boot proper with working
  # display init, ext4, and distro boot support.
  ubootR36S = pkgs.stdenvNoCC.mkDerivation {
    pname = "uboot-r36s-armbian";
    version = "2024.01-armbian";
    src = ./blobs;
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out
      cp $src/u-boot-rockchip.bin $out/
    '';
  };
in
{
  options.hardware.r36s.uboot = lib.mkOption {
    type = lib.types.package;
    default = ubootR36S;
    description = "U-Boot package for the R36S";
  };

  config = {
    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = true;

    hardware.enableRedistributableFirmware = lib.mkForce false;

    boot.kernelParams = [
      "console=ttyS2,1500000n8"
      "console=tty0"
      "loglevel=4"
      "usbcore.autosuspend=-1"
    ];

    # Faster initrd decompression on slow Cortex-A35 cores
    # Use full path to build-platform lz4 (cross-compilation can't find it otherwise)
    boot.initrd.compressor = "${pkgs.pkgsBuildHost.lz4.out}/bin/lz4";
    boot.initrd.compressorArgs = [ "-l" ];

    # Load display modules early in initrd so the DRM framebuffer is ready
    # before stage-1 starts, preventing screen glitching after U-Boot logo
    boot.initrd.kernelModules = [
      "rockchipdrm"
      "panel_generic_dsi"
      "phy_rockchip_inno_dsidphy"
    ];

    boot.kernelPackages = pkgs.linuxPackages_latest;

    # Add R36S device tree to kernel + enable required drivers
    boot.kernelPatches = [{
      name = "r36s-device-tree";
      patch = ./patches/0001-add-r36s-device-tree.patch;
      structuredExtraConfig = {
        # Joystick (all mainline: adc-joystick + gpio-mux + io-channel-mux)
        JOYSTICK_ADC = lib.kernel.module;
        MUX_GPIO = lib.kernel.module;
        IIO_MUX = lib.kernel.module;
        ROCKCHIP_SARADC = lib.kernel.module;
        KEYBOARD_GPIO = lib.kernel.module;
        INPUT_EVDEV = lib.kernel.module;

        # Display (MIPI DSI)
        # DRM_ROCKCHIP auto-enables ROCKCHIP_VOP + ROCKCHIP_DW_MIPI_DSI sub-drivers.
        # Panel driver is out-of-tree (panel-generic-dsi), not the mainline NV3051D.
        DRM_ROCKCHIP = lib.kernel.module;
        PHY_ROCKCHIP_INNO_DSIDPHY = lib.kernel.module;

        # GPU (Panfrost - open source Mali Bifrost)
        DRM_PANFROST = lib.kernel.module;

        # Audio (RK817 PMIC codec via I2S)
        # SND_SOC_ROCKCHIP is auto-enabled by arm64 defconfig
        SND_SOC_ROCKCHIP_I2S = lib.kernel.module;
        SND_SOC_RK817 = lib.kernel.module;

        # USB gadget for debug ethernet
        USB_DWC2 = lib.kernel.module;
        USB_GADGET = lib.kernel.yes;
        USB_ETH = lib.kernel.module;
      };
    }];

    # Build and load the ROCKNIX generic-dsi panel driver
    boot.extraModulePackages = let
      kernel = config.boot.kernelPackages.kernel;
    in [
      (pkgs.callPackage panelGenericDsi { inherit lib kernel; })
    ];

    # Blacklist mainline NV3051D driver (it lacks R36S-specific init sequence)
    boot.blacklistedKernelModules = [ "panel_newvision_nv3051d" ];

    hardware.deviceTree = {
      enable = true;
      filter = "*rk3326-r36s.dtb";
      # Use FDT (exact path) instead of FDTDIR so U-Boot doesn't need fdtfile env var
      name = "rockchip/rk3326-r36s.dtb";
    };

    # GPU - Panfrost (open-source Mali Bifrost driver via Mesa)
    hardware.graphics.enable = true;

    # USB gadget ethernet for headless SSH access during bringup.
    # Connect R36S to laptop via USB-C, then:
    #   sudo ip addr add 10.0.0.1/24 dev usb0
    #   ssh root@10.0.0.2  (password: nixos)
    boot.kernelModules = [ "g_ether" ];
    networking.interfaces.usb0 = {
      ipv4.addresses = [{
        address = "10.0.0.2";
        prefixLength = 24;
      }];
    };
  };
}
