# --search-prefix - 
#  "x86_64-linux-gnu" -- must handle how to strip away -gnu. Shall they all be -gnu, or some -musl?
declare -a targets=("x86_64-windows-gnu" "x86_64-linux-gnu" "x86_64-macos-gnu")
mkdir -p "artifacts/"

for target_full in "${targets[@]}"; do
    target=$(sed 's/-[a-z]*$//' <<< "$target_full")
    mkdir -p artifacts/$target
    echo "Building target ${target}..."	    
    zig build -Dtarget=${target_full} -Drelease-safe --prefix artifacts/${target}/
    cp README.md artifacts/${target}/bin
    cp LICENSE artifacts/${target}/bin
    cp CREDITS artifacts/${target}/bin
    cp xbuild/libs/${target}/* artifacts/${target}/bin
    cd artifacts/${target}/bin
    tar cfJ ${target}.tar.xz *
    mv ${target}.tar.xz ../../
    cd ../../..
done

