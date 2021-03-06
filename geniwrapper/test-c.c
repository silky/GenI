#include <stdio.h>
#include <stdlib.h>
#include "MinimalGenI_stub.h"
#include "StartEnd.h"

char* slurp(const char* filename);

int main(int argc, char *argv[]) {
  char *macros_fn;
  char *lexicon_fn;
  char *lexicon2;
  char *test_sem;
  char *root_ft;
  char *morphcmd;
  char *result;
  char *result2;
  void *geni_st;
 
  if (argc < 7) {
    printf("Usage: %s <macros-file> <lexicon-file> <lexicon-file-2> <sem-file> <root-feat> <morph-cmd>\n", argv[0]);
    printf("NB: It's OK for lexicons 1 and 2 to be the same file\n");
    printf("NB: supplying different files lets us compare the realize/realizeWith functions\n");
    printf("Root feature can be the empty string\n");
    return 2;
  }

  HsStart();
  macros_fn=argv[1];
  lexicon_fn=argv[2];
  lexicon2=slurp(argv[3]);
  test_sem=slurp(argv[4]);
  root_ft=argv[5];
  morphcmd=argv[6];

  // go!
  geni_st=geni_init(macros_fn, lexicon_fn, morphcmd);
  if ( geni_st == NULL ) {
    fprintf(stderr, "Could not initialise GenI wrapper");
    exit(1);
  }
  result=geni_realize(geni_st, "", test_sem, root_ft);
  printf("{\"lexicon1\": %s\n", result);
  result2=geni_realize(geni_st, lexicon2, test_sem, root_ft);
  printf(",\"lexicon2\": %s}\n", result2);

  geni_free(result);
  HsEnd();
  free(lexicon2);
  free(test_sem);
}

// this allocates a string you must free
char* slurp(const char* filename) {
  char *contents;
  FILE *fp;

  fp = fopen(filename, "r");
  if (fp == NULL) {
    fprintf(stderr, "Could not open %s", filename);
    exit(1);
  }
  fseek(fp, 0L, SEEK_END);
  long s = ftell(fp);
  rewind(fp);
  contents = malloc(s);
  if ( fp == NULL ) {
    fprintf(stderr, "Could not read %s", filename);
    exit(1);
  }
  fread(contents, s, 1, fp);
  fclose(fp);
  fp = NULL;
  return contents;
}
