# Do not edit! This file was generated via Makefile
FROM registry.ci.openshift.org/openshift/release:golang-1.17 as builder

COPY . .
RUN make install test-install

FROM openshift/origin-base
USER 65532

COPY --from=builder /go/bin/event_display /usr/bin/event_display
ENTRYPOINT ["/usr/bin/event_display"]
