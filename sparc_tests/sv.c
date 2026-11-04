/* recursion depth >> NWINDOWS: the overflow/underflow handlers run thousands of
 * times; fib(7) does a ta 1 each visit (987 times for fib(22)) */
static int fib(int n) {
  if(n == 7) {
    asm volatile("ta 1");
  }
  return n < 2 ? n : fib(n-1) + fib(n-2);
}
static int deep(int n) { return n == 0 ? 0 : 1 + deep(n - 1); }
int main(void) {
  return fib(22) + deep(100);   /* 17711 + 100 */
}
