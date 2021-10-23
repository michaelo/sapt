echo off
setlocal EnableDelayedExpansion
: Require version as argument
IF "%1"=="" (
    echo Error: No version provided
    goto done
)

set OUT_BASEDIR=artifacts_win
md %OUT_BASEDIR%
: TODO: extract version from config.zig
set VERSION=%1
echo BUILDING v%VERSION%
: TODO: Have Windows-builds use zip
for %%t in (x86_64-windows-gnu x86_64-linux-gnu x86_64-macos-gnu) do (
    set TARGET=%%t
    set TARGET_STRIPPED=!TARGET:-gnu=!
    set TARGET_STRIPPED=!TARGET_STRIPPED:-musl=!
    echo TARGET: !TARGET!

    zig build -Dtarget=!TARGET! -Drelease-safe --prefix %OUT_BASEDIR%\!TARGET_STRIPPED!\
    copy README.md %OUT_BASEDIR%\!TARGET_STRIPPED!\bin
    copy LICENSE %OUT_BASEDIR%\!TARGET_STRIPPED!\bin
    copy xbuild\libs\!TARGET_STRIPPED!\* %OUT_BASEDIR%\!TARGET_STRIPPED!\bin

    cd %OUT_BASEDIR%\!TARGET_STRIPPED!\bin
    tar cfz ..\sapt-v%VERSION%-!TARGET_STRIPPED!.tar.xz *
    move ..\sapt-v%VERSION%-!TARGET_STRIPPED!.tar.xz ..\..\
    cd ..\..\..
)

:done