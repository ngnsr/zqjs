// Code that can never run is not emitted.
for (;;) {
  if (print('once')) continue; else break;
  print('dead');
}
for (;;) {}
print('dead: no break above');
