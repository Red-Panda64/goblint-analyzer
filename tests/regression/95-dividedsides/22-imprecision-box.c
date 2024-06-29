// PARAM: --enable solvers.td3.narrow-sides.enabled --disable solvers.td3.narrow-sides.stable --enable ana.int.interval --disable ana.int.def_exc --enable ana.base.priv.protection.changes-only

#include <pthread.h>

int glob1 = 0;
int glob2 = 0;
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;

void *t_fun1(void *arg) {
  pthread_mutex_lock(&mutex);
  glob1++;
  pthread_mutex_unlock(&mutex);
}

void *t_fun2(void *arg) {
  pthread_mutex_lock(&mutex);
  if (glob1 < 100)
    glob2 = glob1;
  pthread_mutex_unlock(&mutex);
}

int main(void) {
  pthread_t id;
  pthread_create(&id, NULL, t_fun2, NULL);
  pthread_create(&id, NULL, t_fun1, NULL);
  pthread_mutex_lock(&mutex);
  __goblint_check(glob2 <= 100);
  pthread_mutex_unlock(&mutex);
  return 0;
}
