wd=test2

if [ -d $wd ]; then
    rm -r $wd
fi

( time braker.pl --genome=../genome.fa --hints=../ep.hints --epmode --softmasking --workingdir=$wd --cleanup ) &> test2.log
