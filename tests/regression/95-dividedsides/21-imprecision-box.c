// PARAM: --enable solvers.td3.narrow-sides.enabled --disable solvers.td3.narrow-sides.stable --enable ana.int.interval --disable ana.int.def_exc --enable ana.base.priv.protection.changes-only

#include <pthread.h>

int glob = 0;
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;

void *t_fun(void *arg) {
  int flag = 0;
  for (int i = 0; i != 10; i++) {
    pthread_mutex_lock(&mutex);
    if (i == 0) {
      glob = 1;
    } else {
      glob = 2;
    }
    pthread_mutex_unlock(&mutex);
  }
}

int main(void) {
  pthread_t id;
  pthread_create(&id, NULL, t_fun, NULL);
  pthread_mutex_lock(&mutex);
  __goblint_check(glob >= 0 && glob <= 2);
  pthread_mutex_unlock(&mutex);
  return 0;
}
