wn() {
  worker-new . "$@"
}

wcont() {
  worker-continue . "$@"
}

wr() {
  worker-redirect . "$@"
}

ws() {
  worker-status .
}

wp() {
  worker-pause .
}

wk() {
  worker-kill . "$@"
}

wsb() {
  worker-stitch-bind . "$@"
}

wprd() {
  worker-prd . "$@"
}

wt() {
  worker-test . "$@"
}

wts() {
  worker-test-status .
}
