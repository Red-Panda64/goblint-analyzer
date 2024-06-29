// PARAM: --enable solvers.td3.narrow-sides.enabled --enable ana.int.interval --enable ana.base.priv.protection.changes-only

#include <pthread.h>

int glob = 0;
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;

void *t_fun(void *arg) {
  for (int i = 0; i != 10; i++) {
    int flag = i != 0;
    pthread_mutex_lock(&mutex);
    glob = flag;
    pthread_mutex_unlock(&mutex);
  }
}

int main(void) {
  pthread_t id;
  pthread_create(&id, NULL, t_fun, NULL);
  pthread_mutex_lock(&mutex);
  __goblint_check(glob >= 0 && glob <= 1);
  pthread_mutex_unlock(&mutex);
  return 0;
}
