FROM docker.io/erlang:29-alpine AS build
COPY --from=ghcr.io/gleam-lang/gleam:v1.19.2-erlang-alpine /bin/gleam /bin/gleam
COPY . /app/
RUN cd /app && gleam export erlang-shipment

FROM docker.io/erlang:29-alpine
RUN \
  addgroup --system mud && \
  adduser --system mud -g mud
COPY --from=build /app/build/erlang-shipment /app
COPY ./maps /app/maps
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
