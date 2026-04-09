wn() {
  worker-new . "$@"
}

wc() {
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
