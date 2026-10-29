// Feed arbitrary bytes to the embedded mruby (parser, codegen and VM) as Ruby source.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <mruby.h>
#include <mruby/compile.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 1) return 0;
  char *code = (char *)malloc(size + 1);
  if (!code) return 0;
  memcpy(code, data, size);
  code[size] = '\0';
  mrb_state *mrb = mrb_open();
  if (mrb) {
    mrb_load_string(mrb, code);
    mrb_close(mrb);
  }
  free(code);
  return 0;
}
