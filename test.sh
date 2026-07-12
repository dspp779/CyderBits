tmp=$HOME/.tmp

rm -rf $tmp/cx25-override

WINEDLLOVERRIDES='kernel32=b;kernelbase=b' \
WINEDEBUG=trace+loaddll,trace+module \
arch -x86_64 env WINEPREFIX=$tmp/cx25-override \
  install/wine-cx25-x86_64/bin/wine wineboot -u 2>&1 | tee $tmp/cx25-override.log

echo "exit: $?"
egrep -i 'kernel32|kernelbase|builtin|lib/wine|fail|c0000135' $tmp/cx25-override.log | tail -30
