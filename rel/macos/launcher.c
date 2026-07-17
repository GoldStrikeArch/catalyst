/* Native arm64 launcher for the packaged macOS app.
 *
 * macOS LaunchServices reads the Mach-O header of an app bundle's main executable
 * (CFBundleExecutable) to decide the app's architecture. desktop_deployment makes
 * that main executable a `#!/bin/bash` script (Contents/MacOS/run), which has no
 * Mach-O header, so LaunchServices mislabels the bundle "Intel" and launches the
 * x86_64 slice of /bin/bash -> the Rosetta / "Intel app" prompt, even though every
 * binary we ship (beam.smp, NIFs, wx, esbuild/tailwind, rg/fd/sd/ast-grep) is
 * native arm64.
 *
 * This stub is a real arm64 Mach-O. We install it as CFBundleExecutable; it simply
 * execs the sibling `run` script, which sets up the release environment and boots
 * the BEAM. LaunchServices then sees an arm64 binary and launches natively.
 */
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <libgen.h>
#include <mach-o/dyld.h>

int main(int argc, char *argv[]) {
  char exe[PATH_MAX];
  uint32_t size = sizeof(exe);
  if (_NSGetExecutablePath(exe, &size) != 0) return 70;

  char real[PATH_MAX];
  if (realpath(exe, real) == NULL) return 71;

  char run[PATH_MAX];
  snprintf(run, sizeof(run), "%s/run", dirname(real)); /* .../Contents/MacOS/run */

  char **args = calloc(argc + 1, sizeof(char *));
  if (args == NULL) return 73;
  args[0] = run;
  for (int i = 1; i < argc; i++) args[i] = argv[i];
  args[argc] = NULL;

  execv(run, args);
  perror("execv"); /* only reached if exec fails */
  return 72;
}
