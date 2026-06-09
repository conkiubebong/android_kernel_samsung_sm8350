#!/bin/bash
set -e

export ARCH=arm64
export PRODUCT_NAME=b2q
export PROJECT_NAME=b2q
export BUILD_NUMBER=F711NKSSDKZB2

KERNEL_DIR="$(pwd)"
OUT="$KERNEL_DIR/out"
MOD_STAGING="$KERNEL_DIR/out/modules_install"
SCRIPT_DIR="$KERNEL_DIR/daomai-script"

mkdir -p "$OUT"

BUILD_CROSS_COMPILE="$KERNEL_DIR/toolchain/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin/aarch64-linux-android-"
KERNEL_LLVM_BIN="$KERNEL_DIR/toolchain/llvm-arm-toolchain-ship/10.0/bin/clang"
CLANG_TRIPLE=aarch64-linux-gnu-

COMMON_MAKE_ARGS=(
  -j"$(nproc)"
  -C "$KERNEL_DIR"
  O="$OUT"
  DTC_EXT="$KERNEL_DIR/tools/dtc"
  LOCALVERSION=-30959342
  BUILD_NUMBER=F711NKSSDKZB2
  ARCH=arm64
  PRODUCT_NAME=b2q
  PROJECT_NAME=b2q
  CROSS_COMPILE="$BUILD_CROSS_COMPILE"
  REAL_CC="$KERNEL_LLVM_BIN"
  CLANG_TRIPLE=aarch64-linux-gnu-
  CONFIG_SECTION_MISMATCH_WARN_ONLY=y
)

# 1) defconfig
make "${COMMON_MAKE_ARGS[@]}" vendor/stock/b2q_kor_singlex_defconfig

# 2) build kernel + in-tree + techpack modules
make "${COMMON_MAKE_ARGS[@]}"

# 3) stage all *.ko vào out/modules_install/lib/modules/<ver>/...
rm -rf "$MOD_STAGING"
make "${COMMON_MAKE_ARGS[@]}" \
  INSTALL_MOD_PATH="$MOD_STAGING" \
  INSTALL_MOD_STRIP=1 \
  modules_install

cp "$OUT/arch/arm64/boot/Image" "$KERNEL_DIR/arch/arm64/boot/Image"

# ========================================================================
# 4) Repack boot.img: chỉ thay kernel
# ========================================================================
cd "$SCRIPT_DIR"
chmod +x libmagiskboot.so

if [ ! -f boot.img ]; then
  echo "!! Thiếu $SCRIPT_DIR/boot.img — bỏ qua repack boot.img"
else
  rm -rf boot_work
  mkdir boot_work
  cp boot.img libmagiskboot.so boot_work/
  (
    cd boot_work
    ./libmagiskboot.so unpack boot.img
    rm -f kernel
    cp "$KERNEL_DIR/arch/arm64/boot/Image" kernel
    ./libmagiskboot.so repack boot.img boot-new.img
    cp boot-new.img "$SCRIPT_DIR/boot-new.img"
  )
fi

# ========================================================================
# 5) Repack vendor_boot.img: thay TẤT CẢ *.ko trong vendor ramdisk
# ========================================================================
if [ ! -f "$SCRIPT_DIR/vendor_boot.img" ]; then
  echo "!! Thiếu $SCRIPT_DIR/vendor_boot.img — bỏ qua repack vendor_boot"
  exit 0
fi

cd "$SCRIPT_DIR"
rm -rf vboot_work
mkdir vboot_work
cp vendor_boot.img libmagiskboot.so vboot_work/

cd vboot_work
./libmagiskboot.so unpack vendor_boot.img
# magiskboot tạo ra: kernel (thường rỗng với vendor_boot), ramdisk.cpio, dtb, vendor_ramdisk/*

# Một số vendor_boot v4 có nhiều fragment ramdisk → magiskboot gom thành ramdisk.cpio.
if [ ! -f ramdisk.cpio ]; then
  echo "!! Không tìm thấy ramdisk.cpio sau khi unpack vendor_boot.img"
  ls -la
  exit 1
fi

# Đổ ramdisk ra cây thư mục
mkdir -p ramdisk_extracted
( cd ramdisk_extracted && cpio -i --no-absolute-filenames < ../ramdisk.cpio )

# Bơm *.ko mới build vào ramdisk_extracted/lib/modules/5.4-gki/
# Z Flip 3 (b2q) Samsung dùng subdir cố định "5.4-gki" thay vì version thật.
MOD_DST="ramdisk_extracted/lib/modules/5.4-gki"
mkdir -p "$MOD_DST"

echo "==> Copy modules built ra $MOD_DST"
# Lấy mọi .ko trong staging, đặt flat (cùng tên file) — ghi đè bản stock
find "$MOD_STAGING" -name '*.ko' -print0 | while IFS= read -r -d '' ko; do
  base="$(basename "$ko")"
  # Chỉ ghi đè nếu vendor ramdisk gốc đã có module trùng tên,
  # tránh thêm module thừa làm modprobe.dep sai. Comment 2 dòng dưới nếu muốn copy hết.
  if [ -e "$MOD_DST/$base" ]; then
    cp -f "$ko" "$MOD_DST/$base"
  fi
done

# Nếu vendor ramdisk có modules.dep / modules.alias / modules.softdep — regen từ staging
for f in modules.dep modules.alias modules.softdep modules.load; do
  src="$(find "$MOD_STAGING" -name "$f" | head -n1)"
  if [ -n "$src" ] && [ -e "$MOD_DST/$f" ]; then
    cp -f "$src" "$MOD_DST/$f"
  fi
done

# Repack cpio (giữ nguyên format newc như Android dùng)
( cd ramdisk_extracted && find . | cpio -o -H newc --owner=0:0 > ../ramdisk.cpio.new )
mv ramdisk.cpio.new ramdisk.cpio

./libmagiskboot.so repack vendor_boot.img vendor_boot-new.img
cp vendor_boot-new.img "$SCRIPT_DIR/vendor_boot-new.img"

echo
echo "==> XONG"
echo "    Kernel:        $KERNEL_DIR/arch/arm64/boot/Image"
echo "    boot-new:      $SCRIPT_DIR/boot-new.img"
echo "    vendor_boot:   $SCRIPT_DIR/vendor_boot-new.img"
echo "    modules stage: $MOD_STAGING"
