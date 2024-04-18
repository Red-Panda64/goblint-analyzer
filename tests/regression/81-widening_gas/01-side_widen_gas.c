// PARAM: --set solvers.td3.side_widen always --set solvers.td3.side_widen_gas 3 --enable ana.int.interval
#include <pthread.h>
#include <goblint.h>

int a = 0;
int b = 0;
int c = 0;

pthread_mutex_t A = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t B = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t C = PTHREAD_MUTEX_INITIALIZER;

void *set_to_1(void *arg) {
  pthread_mutex_lock(&A);
  a = 1;
  pthread_mutex_unlock(&A);
  pthread_mutex_lock(&B);
  b = 1;
  pthread_mutex_unlock(&B);
  pthread_mutex_lock(&C);
  c = 1;
  pthread_mutex_unlock(&C);
  return NULL;
}

void *set_to_2(void *arg) {
  pthread_mutex_lock(&B);
  b = 2;
  pthread_mutex_unlock(&B);
  pthread_mutex_lock(&C);
  c = 2;
  pthread_mutex_unlock(&C);
  return NULL;
}

void *set_to_3(void *arg) {
  pthread_mutex_lock(&C);
  c = 3;
  pthread_mutex_unlock(&C);
  return NULL;
}

int main(void) {
  // don't care about id
  pthread_t id;
  pthread_create(&id, NULL, set_to_1, NULL);
  pthread_create(&id, NULL, set_to_2, NULL);
  pthread_create(&id, NULL, set_to_3, NULL);

  pthread_mutex_lock(&A);
  __goblint_check(a >= 0);
  __goblint_check(a <= 1);
  pthread_mutex_unlock(&A);

  pthread_mutex_lock(&B);
  __goblint_check(b >= 0);
  __goblint_check(b <= 2);
  pthread_mutex_unlock(&B);

  pthread_mutex_lock(&C);
  __goblint_check(c >= 0);
  __goblint_check(c <= 3); // UNKNOWN (widen)
  pthread_mutex_unlock(&C);

  return 0;
}
