/* One source builds a dependency and a consumer. No rpath is added; leaving
 * the dependency outside loader search paths tests dlopen failure honestly. */
#ifdef RUNTIME_FIXTURE_NEEDS_DEPENDENCY
extern unsigned ziggurat_runtime_dependency_anchor(void);
unsigned ziggurat_runtime_consumer(void) { return ziggurat_runtime_dependency_anchor(); }
#else
unsigned ziggurat_runtime_dependency_anchor(void) { return 19; }
#endif
