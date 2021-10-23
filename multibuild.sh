OUT_BASEDIR=artifacts
mkdir -p $OUT_BASEDIR

# Get version from config.zig
VERSION=$(cat VERSION)

declare -a TARGETS=("x86_64-windows-gnu" "x86_64-linux-gnu" "x86_64-macos-gnu")

# TODO: Have Windows-buils use zip
for TARGET_FULL in "${TARGETS[@]}"; do
    TARGET=$(sed 's/-[a-z]*$//' <<< "$TARGET_FULL")
    mkdir -p ${OUT_BASEDIR}/${TARGET}
    echo "Building target ${TARGET}..."	    
    if zig build -Dtarget=${TARGET_FULL} -Drelease-safe --prefix ${OUT_BASEDIR}/${TARGET}/; then
    OUTDIR=${OUT_BASEDIR}/${TARGET}/bin
    cp README.md ${OUTDIR}
    cp LICENSE ${OUTDIR}
    cp CREDITS ${OUTDIR}
    cp xbuild/libs/${TARGET}/* ${OUTDIR}
    cd ${OUTDIR}
    # TODO: If windows: create zip, otherwise .tar.xz
    if [[ $TARGET == *"windows"* ]]; then
        zip -9 ../../sapt-v${VERSION}-${TARGET}.zip *
    else
        tar cfJ ../../sapt-v${VERSION}-${TARGET}.tar.xz *
    fi
    cd ../../..
    fi
done
