Problem: this only works when goblint is built with tracing enabled...
Should this kind of test on trace data even exist?
  $ goblint --trace gas --set solvers.td3.side_widen always --set solvers.td3.side_widen_gas 4 --enable ana.int.interval 01-side_widen_gas.c 2> tmp > /dev/null
  $ grep -E 'reducing gas.*:(a|b|c):.*4 -> 3$' tmp | wc -l
  6
  $ grep -E 'reducing gas.*:(a|b|c):.*3 -> 2$' tmp | wc -l
  6
  $ grep -E 'reducing gas.*:(a|b|c):.*2 -> 1$' tmp | wc -l
  6
  $ grep -E 'reducing gas.*:(b|c):.*1 -> 0$' tmp | wc -l
  4
  $ grep -E 'reducing gas.*:a:.*1 -> 0$' tmp | wc -l
  0
