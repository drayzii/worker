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
