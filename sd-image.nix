# SD image configuration for Rockchip RK3326 (R36S)
# Handles U-Boot placement at the correct raw SD card offsets.
{ config, pkgs, lib, modulesPath, ... }:

let
  toplevel = config.system.build.toplevel;
  bootargs = "init=${toplevel}/init "
    + lib.concatStringsSep " " config.boot.kernelParams;
in
{
  imports = [
    # Import base sd-image module only (not sd-image-aarch64.nix which pulls in RPi firmware)
    (modulesPath + "/installer/sd-card/sd-image.nix")
  ];

  sdImage = {
    # Use custom ext4 builder with U-Boot-compatible features
    # (disables metadata_csum, 64bit, orphan_file)
    rootFilesystemCreator = ./make-ext4-fs.nix;

    # 16 MiB gap before first partition to fit U-Boot blobs.
    # idbloader.img sits at 32KB, u-boot.itb at 8MB.
    firmwarePartitionOffset = 16;

    # U-Boot boot.ini on FAT partition.
    # The Armbian U-Boot auto-loads and runs boot.ini from mmc 1:1 (FAT).
    # Uses explicit load commands (same approach as Armbian) to load
    # NixOS kernel, initrd, and DTB from mmc 1:2 (ext4 root partition).
    populateFirmwareCommands = ''
      # Boot logo displayed by Armbian U-Boot splash
      cp ${./assets/boot-logo.bmp} firmware/logo.bmp

      # Armbian panel overlay and env (required by Armbian U-Boot)
      cp ${./assets/firmware/logo.env} firmware/logo.env
      mkdir -p firmware/ScreenFiles/Panel4
      cp ${./assets/firmware/ScreenFiles/Panel4/mipi-panel.dtbo} firmware/ScreenFiles/Panel4/mipi-panel.dtbo

      # Generate boot.ini matching Armbian's exact boot flow:
      # - DTB name: rk3326-gameconsole-r36s.dtb (Armbian's name)
      # - Panel DTBO overlay loaded from FAT and applied via fdt
      # - Initrd named uInitrd (Armbian convention)
      # - Stage marker files for boot diagnostics
      cat > firmware/boot.ini << 'BOOTINI'
odroidgoa-uboot-config

setenv dtbo_loadaddr  0x01e00000
setenv dtb_loadaddr   0x01f00000
setenv loadaddr       0x02000000
setenv logaddr        0x00100000

# Stage 1: boot.ini is executing
echo "NixOS: Stage 1 - boot.ini running"
mw.b ''${logaddr} 0x31 1
fatwrite mmc 1:1 ''${logaddr} stage1-bootini.ok 1

echo "NixOS: loading kernel..."
if load mmc 1:2 ''${loadaddr} boot/Image
then
    # Stage 2: kernel loaded
    echo "NixOS: Stage 2 - kernel loaded"
    mw.b ''${logaddr} 0x32 1
    fatwrite mmc 1:1 ''${logaddr} stage2-kernel.ok 1

    echo "NixOS: loading initrd..."
    setexpr initrd_loadaddr ''${loadaddr} + ''${filesize}
    setexpr initrd_loadaddr ''${initrd_loadaddr} + 0x01000000
    if load mmc 1:2 ''${initrd_loadaddr} boot/uInitrd
    then
        setenv ramdisk_size ''${filesize}
        # Stage 3: initrd loaded
        echo "NixOS: Stage 3 - initrd loaded"
        mw.b ''${logaddr} 0x33 1
        fatwrite mmc 1:1 ''${logaddr} stage3-initrd.ok 1

        echo "NixOS: loading device tree..."
        if load mmc 1:2 ''${dtb_loadaddr} boot/dtb/rockchip/rk3326-gameconsole-r36s.dtb
        then
            # Stage 4: DTB loaded
            echo "NixOS: Stage 4 - dtb loaded"
            mw.b ''${logaddr} 0x34 1
            fatwrite mmc 1:1 ''${logaddr} stage4-dtb.ok 1

            echo "NixOS: loading panel overlay..."
            if load mmc 1:1 ''${dtbo_loadaddr} ScreenFiles/Panel4/mipi-panel.dtbo
            then
                echo "NixOS: applying panel overlay"
                fdt addr ''${dtb_loadaddr}
                fdt resize 8192
                fdt apply ''${dtbo_loadaddr}
            else
                echo "NixOS: no panel overlay, continuing without"
            fi

            # Stage 5: about to call booti
            setenv bootargs "BOOTARGS_PLACEHOLDER"
            echo "NixOS: Stage 5 - calling booti"
            mw.b ''${logaddr} 0x35 1
            fatwrite mmc 1:1 ''${logaddr} stage5-booti.ok 1

            booti ''${loadaddr} ''${initrd_loadaddr}:''${ramdisk_size} ''${dtb_loadaddr}

            # Stage 6: booti returned (should never happen on success)
            echo "NixOS: Stage 6 - booti RETURNED (failed!)"
            mw.b ''${logaddr} 0x36 1
            fatwrite mmc 1:1 ''${logaddr} stage6-booti-failed.err 1
        fi
    fi
fi

echo "NixOS boot FAILED!"
mw.b ''${logaddr} 0x46 1
fatwrite mmc 1:1 ''${logaddr} FAILED.txt 1
sleep 30
BOOTINI

      # Inject actual bootargs (contains Nix store paths that break heredoc)
      sed -i "s|BOOTARGS_PLACEHOLDER|${bootargs}|" firmware/boot.ini
    '';

    # Root partition: extlinux.conf + fixed-path copies for boot.ini
    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
        -c ${toplevel} -d ./files/boot

      # Create fixed-path copies that boot.ini can load
      # (U-Boot ext4 driver can't follow symlinks)
      cp -L ./files/boot/nixos/*-Image ./files/boot/Image
      cp -L ./files/boot/nixos/*-initrd ./files/boot/uInitrd
      mkdir -p ./files/boot/dtb/rockchip
      # Use Armbian's DTB name so boot.ini matches
      cp -L ./files/boot/nixos/*-dtbs-filtered/rockchip/rk3326-r36s.dtb \
        ./files/boot/dtb/rockchip/rk3326-gameconsole-r36s.dtb
    '';

    # Write U-Boot and panel files to raw SD card after image is assembled
    postBuildCommands = let
      uboot = config.hardware.r36s.uboot;
      panelDtbo = ./assets/firmware/ScreenFiles/Panel4/mipi-panel.dtbo;
      panelDtb = ./assets/firmware/ScreenFiles/Panel4/rg351mp-kernel.dtb;
    in ''
      # Prefer combined u-boot-rockchip.bin (single dd at sector 64)
      if [ -f "${uboot}/u-boot-rockchip.bin" ]; then
        dd if=${uboot}/u-boot-rockchip.bin of=$img \
          conv=fsync,notrunc bs=512 seek=64
      else
        # Fallback: write idbloader + u-boot.itb separately
        dd if=${uboot}/idbloader.img of=$img \
          conv=fsync,notrunc bs=512 seek=64
        dd if=${uboot}/u-boot.itb of=$img \
          conv=fsync,notrunc bs=512 seek=16384
      fi

      # Add panel files with spaces in directory names directly to FAT partition.
      # The nixpkgs FAT builder uses $(find | mmd) which breaks on spaces.
      # mtools can address partitions in raw disk images via @@offset.
      fatOffset=$((START * 512))
      export MTOOLS_SKIP_CHECK=1
      mmd -i "$img@@$fatOffset" "::ScreenFiles/Panel 4"
      mcopy -i "$img@@$fatOffset" ${panelDtbo} "::ScreenFiles/Panel 4/mipi-panel.dtbo"
      mcopy -i "$img@@$fatOffset" ${panelDtb} "::ScreenFiles/Panel 4/rg351mp-kernel.dtb"
    '';

    compressImage = false;
  };
}
