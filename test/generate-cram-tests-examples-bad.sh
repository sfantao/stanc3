dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )" ;
for filename in $(find  $dir/examples-bad -name '*.stan' -printf "%P\n"); do
  changepath=$(echo $filename | sed -e 's/[^\/]*/../g')
  changepath=${changepath::-2}
  printf "  \$ \$TESTDIR/$changepath/../../_build/default/stanc.exe \"\$TESTDIR/$changepath/$filename\"\n\n" &> $dir/examples-bad/${filename}-test.t ; 
done