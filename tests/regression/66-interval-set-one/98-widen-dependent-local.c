// PARAM: --enable ana.int.interval_set --enable exp.priv-distr-init --enable ana.sv-comp.functions
extern int __VERIFIER_nondet_int();

#include <pthread.h>
#include <goblint.h>

// protection priv succeeds
// write fails due to [1,+inf] widen ([1,+inf] join [0,+inf]) -> [-inf,+inf]
// sensitive to eval and widen order!

int g = 0;
int limit; // unknown

pthread_mutex_t A = PTHREAD_MUTEX_INITIALIZER;

void *worker(void *arg )
{
  // just for going to multithreaded mode
  return NULL;
}

int put() {
  pthread_mutex_lock(&A);
  while (g >= limit) { // problematic widen

  }
  __goblint_check(g >= 0); // precise privatization fails
  g++;
  pthread_mutex_unlock(&A);
}

int main(int argc , char **argv )
{
  pthread_t tid;
  pthread_create(& tid, NULL, & worker, NULL);

  int r = __VERIFIER_nondet_int();
  limit = r; // only problematic if limit unknown

  while (1) {
    // only problematic if not inlined
    put();
  }
  return 0;
}
