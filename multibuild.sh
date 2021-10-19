# --search-prefix - 
#  "x86_64-linux-gnu" -- must handle how to strip away -gnu. Shall they all be -gnu, or some -musl?
declare -a targets=("x86_64-windows" "x86_64-macos")
mkdir -p "artifacts/"

for target in "${targets[@]}"; do
    mkdir -p artifacts/$target
    echo "Building target ${target}..."	    
    zig build -Dtarget=${target} -Drelease-safe --prefix artifacts/${target}/
    cp README.md artifacts/${target}/bin
    cp LICENSE artifacts/${target}/bin
    cp xbuild/libs/${target}/* artifacts/${target}/bin
    cd artifacts/${target}/bin
    tar cfJ ${target}.tar.xz *
    mv ${target}.tar.xz ../../
    cd ../../..
done

