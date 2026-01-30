docker run -it --rm --pull always -v $(pwd):/data \
  ghcr.io/systemed/tilemaker:master \
  /data/$1 \
  --output /data/$1.pmtiles
