// PARAM: --enable solvers.td3.narrow-sides.enabled --enable solvers.td3.narrow-sides.stable --enable ana.int.interval --set ana.activated[+] thread --enable ana.base.priv.protection.changes-only

#include <pthread.h>

int glob = 0;
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;

void *t_fun(void *arg) {
  pthread_mutex_lock(&mutex);
  glob = glob;
  pthread_mutex_unlock(&mutex);
  pthread_mutex_lock(&mutex);
  if (glob < 10)
    glob++;
  pthread_mutex_unlock(&mutex);
}

int main(void) {
  pthread_t id;
  pthread_create(&id, NULL, t_fun, NULL);
  pthread_mutex_lock(&mutex);
  __goblint_check(glob <= 10);
  pthread_mutex_unlock(&mutex);
  return 0;
}
