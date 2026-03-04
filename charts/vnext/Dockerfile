FROM alpine:3.22

RUN apk add --no-cache curl kubectl jq\
  && addgroup -g 1000 vnext \
  && adduser -D -u 1000 -G vnext -s /bin/sh vnext
USER vnext
WORKDIR /home/vnext