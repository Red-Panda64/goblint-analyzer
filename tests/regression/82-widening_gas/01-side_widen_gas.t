Problem: this only works when goblint is built with tracing enabled...
Should this kind of test on trace data even exist?
  $ goblint --trace gas --set solvers.td3.side_widen always --set solvers.td3.side_widen_gas 4 --enable ana.int.interval 01-side_widen_gas.c 2> tmp > /dev/null
  $ COUNT=$(grep -E 'reducing gas.*:a:.*4 -> 3$' tmp | wc -l)
  $ [ $COUNT -ge '1' ]
  $ COUNT=$(grep -E 'reducing gas.*:b:.*4 -> 3$' tmp | wc -l)
  $ [ $COUNT -ge '1' ]
  $ COUNT=$(grep -E 'reducing gas.*:c:.*4 -> 3$' tmp | wc -l)
  $ [ $COUNT -ge '1' ]
  $ COUNT=$(grep -E 'reducing gas.*:a:.*3 -> 2$' tmp | wc -l)
  $ [ $COUNT -ge '1' ]
  $ COUNT=$(grep -E 'reducing gas.*:b:.*3 -> 2$' tmp | wc -l)
  $ [ $COUNT -ge '1' ]
  $ COUNT=$(grep -E 'reducing gas.*:c:.*3 -> 2$' tmp | wc -l)
  $ [ $COUNT -ge '1' ]
  $ COUNT=$(grep -E 'reducing gas.*:a:.*2 -> 1$' tmp | wc -l)
  $ [ $COUNT -ge '1' ]
  $ COUNT=$(grep -E 'reducing gas.*:b:.*2 -> 1$' tmp | wc -l)
  $ [ $COUNT -ge '1' ]
  $ COUNT=$(grep -E 'reducing gas.*:c:.*2 -> 1$' tmp | wc -l)
  $ [ $COUNT -ge '1' ]
  $ COUNT=$(grep -E 'reducing gas.*:b:.*1 -> 0$' tmp | wc -l)
  $ [ $COUNT -ge '1' ]
  $ COUNT=$(grep -E 'reducing gas.*:c:.*1 -> 0$' tmp | wc -l)
  $ [ $COUNT -ge '1' ]
  $ grep -E 'reducing gas.*:a:.*1 -> 0$' tmp | wc -l
  0
