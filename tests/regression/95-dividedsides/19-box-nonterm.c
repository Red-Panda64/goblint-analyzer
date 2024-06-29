// PARAM: --enable solvers.td3.narrow-sides.enabled --enable ana.int.interval --set ana.activated[+] thread --enable ana.base.priv.protection.changes-only
/*
#include <pthread.h>

int glob1 = 0;
int glob2 = 0;
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;

void *t_fun1(void *arg) {
  pthread_mutex_lock(&mutex);
  __goblint_check (glob1 >= 0);
  glob1 = glob2 + 1;
  pthread_mutex_unlock(&mutex);
}

void *t_fun2(void *arg) {
  pthread_mutex_lock(&mutex);
  __goblint_check (glob2 >= 0);
  glob2 = glob1 + 1;
  pthread_mutex_unlock(&mutex);
}

int main(void) {
  pthread_t id;
  pthread_create(&id, NULL, t_fun1, NULL);
  pthread_create(&id, NULL, t_fun2, NULL);
  return 0;
}
*/