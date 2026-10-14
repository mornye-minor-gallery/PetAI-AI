// Android applications load their system dependencies before the ML engine.
// Loading this engine as a process-wide startup dependency instead interposes
// its protobuf symbols during libandroid's protobuf constructors (SIGSEGV).
// Reproduce the app's load order and keep the probe's symbols local.
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char** argv) {
  void* android = dlopen("libandroid.so", RTLD_NOW | RTLD_GLOBAL);
  if (!android) { fprintf(stderr, "libandroid: %s\n", dlerror()); return 1; }
  void* probe = dlopen("libcheckpoint_probe.so", RTLD_NOW | RTLD_LOCAL);
  if (!probe) { fprintf(stderr, "probe: %s\n", dlerror()); return 1; }
  int (*run)(int, char**) = (int (*)(int, char**))dlsym(probe, "run_probe");
  if (!run) { fprintf(stderr, "entry: %s\n", dlerror()); return 1; }
  return run(argc, argv);
}
