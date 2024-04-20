// PARAM: --set solvers.td3.widen_gas 5 --enable ana.int.interval
#include <goblint.h>

int main(void) {
  // don't care about id
  int a = 0;
  int b = 0;
  int c = 0;
  for(int i = 0; i < 5; i ++) {
    if (a < 3) {
      a += 1;
    }
  }
  for(int i = 0; i < 5; i ++) {
    if (b < 4) {
      b += 1;
    }
  }
  for(int i = 0; i < 5; i ++) {
    if (c < 5) {
      c += 1;
    }
  }

  __goblint_check(a >= 0);
  __goblint_check(a <= 3);
  __goblint_check(b >= 0);
  __goblint_check(b <= 4);
  __goblint_check(c >= 0);
  __goblint_check(c <= 5); // UNKNOWN (widen)

  return 0;
}
