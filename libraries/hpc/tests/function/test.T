setTestOpts([omit_ways(['ghci']), when(fast(), skip), js_skip])

hpc_prefix = "perl hpcrun.pl --clear --exeext={exeext} --hpc={hpc}"

test('tough',
     [extra_files(['../hpcrun.pl']),
      cmd_prefix(hpc_prefix)],
     compile_and_run, ['-fhpc'])

