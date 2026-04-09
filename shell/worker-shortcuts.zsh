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

wprdc() {
  worker-prd . codex "$@"
}

wprda() {
  worker-prd . claude "$@"
}
