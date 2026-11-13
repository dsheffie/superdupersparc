/* pmu: run a command and report the cycles and instructions it took, from
 * the superdupersparc PMU (rd %asr16-19, pmu_rd.s).  The counts are for the
 * whole machine (kernel and every process), so run it on a quiet system.
 *   cc -O -o pmu pmu.c pmu_rd.s
 *   pmu <command> [args...]
 * prints to stderr:  PMU cycles <n> insns <n> ipc <x> : <command> */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

extern void pmu_rd(unsigned long long *cycles, unsigned long long *insns);

int main(int argc, char **argv) {
  unsigned long long c0, i0, c1, i1;
  pid_t pid;
  int status = 0;
  if(argc < 2) {
    fprintf(stderr, "usage: pmu <command> [args...]\n");
    return 2;
  }
  pmu_rd(&c0, &i0);
  pid = fork();
  if(pid < 0) {
    perror("fork");
    return 2;
  }
  if(pid == 0) {
    execvp(argv[1], argv + 1);
    perror(argv[1]);
    _exit(127);
  }
  while(waitpid(pid, &status, 0) < 0) {
  }
  pmu_rd(&c1, &i1);
  fprintf(stderr, "PMU cycles %llu insns %llu ipc %.4f : %s\n", c1 - c0, i1 - i0,
	  (c1 > c0) ? (double)(i1 - i0) / (double)(c1 - c0) : 0.0, argv[1]);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
