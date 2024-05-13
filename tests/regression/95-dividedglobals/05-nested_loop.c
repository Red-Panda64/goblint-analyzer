// PARAM: --enable ana.globals.divide --enable ana.int.interval --set warn_at early --trace priv
#include <pthread.h>
#include <goblint.h>
#include <unistd.h>

pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
int a = 0;

void seta(int newa) {
    pthread_mutex_lock(&mutex);
    a = newa;
    pthread_mutex_unlock(&mutex);
}

void f(void *) {
    for(int i = 0; i < 3; i++) {
      for(int j = 0; j < 3; j++) {
        for(int k = 0; k < 3; k++) {
//          seta(i * j * k);
          pthread_mutex_lock(&mutex);
          a = i * j * k;
          pthread_mutex_unlock(&mutex);

          pthread_mutex_lock(&mutex);
          __goblint_check(a <= 8);
          pthread_mutex_unlock(&mutex);
        }
      }
    }
}

int main(void) {
  pthread_t id;
  pthread_create(&id, NULL, f, NULL);

  pthread_mutex_lock(&mutex);
  __goblint_check(a <= 100);
  pthread_mutex_unlock(&mutex);
  return 0;
}
