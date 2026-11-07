class A {
  final int n;
  A(this.n);
  int next() {
    final doubled = n * 2;
    return doubled - n + 1;
  }
}
