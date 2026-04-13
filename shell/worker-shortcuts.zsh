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

wss() {
  worker-stitch-sync . "$@"
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
