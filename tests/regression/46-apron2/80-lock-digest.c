// SKIP PARAM: --set ana.activated[+] apron --set ana.relation.privatization mutex-meet
// TODO: why does this work? even with earlyglobs
#include <pthread.h>
#include <goblint.h>

int g, h;
pthread_mutex_t a = PTHREAD_MUTEX_INITIALIZER;

void *t2(void *arg) {
  pthread_mutex_lock(&a);
  __goblint_check(h <= g); // TODO: should be h < g?
  pthread_mutex_unlock(&a);
  return NULL;
}

void *t1(void *arg) {
  pthread_t x;
  pthread_create(&x, NULL, t2, NULL);

  pthread_mutex_lock(&a);
  h = 11; g = 12;
  pthread_mutex_unlock(&a);

  return NULL;
}

int main() {
  pthread_mutex_lock(&a);
  h = 9;
  g = 10;
  pthread_mutex_unlock(&a);

  pthread_t x;
  pthread_create(&x, NULL, t1, NULL);
  return 0;
}
